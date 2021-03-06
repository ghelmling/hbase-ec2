#!/usr/bin/env bash

#
# Copyright 2010 The Apache Software Foundation
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -x
export JAVA_HOME=/usr/local/jdk1.6.0_20
ln -s $JAVA_HOME /usr/local/jdk

# Script that is run on each EC2 instance on boot. It is passed in the EC2 user
# data, so should not exceed 16K in size.

MASTER_HOST="%MASTER_HOST%"
ZOOKEEPER_QUORUM="%ZOOKEEPER_QUORUM%"
EXTRA_PACKAGES="%EXTRA_PACKAGES%"
SECURITY_GROUPS=`wget -q -O - http://169.254.169.254/latest/meta-data/security-groups`
IS_MASTER=`echo $SECURITY_GROUPS | awk '{ a = match ($0, "-master$"); if (a) print "true"; else print "false"; }'`
if [ "$IS_MASTER" = "true" ]; then
 MASTER_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/local-hostname`
fi
HADOOP_HOME=`ls -d /usr/local/hadoop-*`
HADOOP_VERSION=`echo $HADOOP_HOME | cut -d '-' -f 2`
HBASE_HOME=`ls -d /usr/local/hbase-*`
HBASE_VERSION=`echo $HBASE_HOME | cut -d '-' -f 2`

export USER="root"

# up file-max
sysctl -w fs.file-max=65535

# up ulimits
echo "root soft nofile 65535" >> /etc/security/limits.conf
echo "root hard nofile 65535" >> /etc/security/limits.conf
ulimit -n 65535

# up epoll limits; ok if this fails, only valid for kernels 2.6.27+
sysctl -w fs.epoll.max_user_instances=65535 > /dev/null 2>&1

[ ! -f /etc/hosts ] &&  echo "127.0.0.1 localhost" > /etc/hosts

# Extra packages

if [ "$EXTRA_PACKAGES" != "" ] ; then
  # format should be <repo-descriptor-URL> <package1> ... <packageN>
  pkg=( $EXTRA_PACKAGES )
  wget -nv -O /etc/yum.repos.d/user.repo ${pkg[0]}
  yum -y update yum
  yum -y install ${pkg[@]:1}
fi

# Ganglia

if [ "$IS_MASTER" = "true" ]; then
  sed -i -e "s|\( *mcast_join *=.*\)|#\1|" \
         -e "s|\( *bind *=.*\)|#\1|" \
         -e "s|\( *mute *=.*\)|  mute = yes|" \
         -e "s|\( *location *=.*\)|  location = \"master-node\"|" \
         /etc/gmond.conf
  mkdir -p /mnt/ganglia/rrds
  chown -R ganglia:ganglia /mnt/ganglia/rrds
  rm -rf /var/lib/ganglia; cd /var/lib; ln -s /mnt/ganglia ganglia; cd
  service gmond start
  service gmetad start
  apachectl start
else
  sed -i -e "s|\( *mcast_join *=.*\)|#\1|" \
         -e "s|\( *bind *=.*\)|#\1|" \
         -e "s|\(udp_send_channel {\)|\1\n  host=$MASTER_HOST|" \
         /etc/gmond.conf
  service gmond start
fi

# Reformat sdb as xfs
umount /mnt
mkfs.xfs -f /dev/sdb
mount -o noatime /dev/sdb /mnt
#mkdir -p /mnt/hadoop/dfs/name
mkdir -p /mnt/hadoop/dfs/data

# Probe for additional instance volumes

# /dev/sdb as /mnt is always set up by base image
DFS_NAME_DIR="/mnt/hadoop/dfs/name"
DFS_DATA_DIR="/mnt/hadoop/dfs/data"
i=2
for d in c d e f g h i j k l m n o p q r s t u v w x y z; do
  m="/mnt${i}"
  mkdir -p $m
  mkfs.xfs -f /dev/sd${d}
  if [ $? -eq 0 ] ; then
    mount -o noatime /dev/sd${d} $m > /dev/null 2>&1
    if [ $i -lt 3 ] ; then # no more than two namedirs
      DFS_NAME_DIR="${DFS_NAME_DIR},${m}/hadoop/dfs/name"
    fi
    DFS_DATA_DIR="${DFS_DATA_DIR},${m}/hadoop/dfs/data"
    i=$(( i + 1 ))
  fi
done

# Hadoop configuration
cat >> $HADOOP_HOME/conf/hadoop-env.sh <<EOF
export HADOOP_OPTS="$HADOOP_OPTS -Djavax.security.auth.useSubjectCredsOnly=false"
export HADOOP_SECURE_DN_USER=hadoop
EOF

( cd /usr/local && ln -s $HADOOP_HOME hadoop ) || true
cat > $HADOOP_HOME/conf/core-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>hadoop.tmp.dir</name>
  <value>/mnt/hadoop</value>
</property>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$MASTER_HOST:8020</value>
</property>
</configuration>
EOF
cat > $HADOOP_HOME/conf/hdfs-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$MASTER_HOST:8020</value>
</property>
<property>
  <name>dfs.name.dir</name>
  <value>$DFS_NAME_DIR</value>
</property>
<property>
  <name>dfs.data.dir</name>
  <value>$DFS_DATA_DIR</value>
</property>
<property>
  <name>dfs.datanode.handler.count</name>
  <value>10</value>
</property>
<property>
  <name>dfs.datanode.max.xcievers</name>
  <value>10000</value>
</property>
</configuration>
EOF
cat > $HADOOP_HOME/conf/mapred-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>mapred.job.tracker</name>
  <value>$MASTER_HOST:8021</value>
</property>
<property>
  <name>io.compression.codecs</name>
  <value>org.apache.hadoop.io.compress.GzipCodec,org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.BZip2Codec,com.hadoop.compression.lzo.LzoCodec,com.hadoop.compression.lzo.LzopCodec</value>
</property>
</configuration>
EOF
# Update classpath to include HBase jars and config
cat >> $HADOOP_HOME/conf/hadoop-env.sh <<EOF
HADOOP_CLASSPATH="$HBASE_HOME/hbase-${HBASE_VERSION}.jar:$HBASE_HOME/lib/zookeeper-3.3.0.jar:$HBASE_HOME/conf"
EOF
# Configure Hadoop for Ganglia
cat > $HADOOP_HOME/conf/hadoop-metrics.properties <<EOF
dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext
dfs.period=10
dfs.servers=$MASTER_HOST:8649
jvm.class=org.apache.hadoop.metrics.ganglia.GangliaContext
jvm.period=10
jvm.servers=$MASTER_HOST:8649
mapred.class=org.apache.hadoop.metrics.ganglia.GangliaContext
mapred.period=10
mapred.servers=$MASTER_HOST:8649
EOF

# HBase configuration

( cd /usr/local && ln -s $HBASE_HOME hbase ) || true
cat > $HBASE_HOME/conf/hbase-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>hbase.rootdir</name>
  <value>hdfs://$MASTER_HOST:8020/hbase</value>
</property>
<property>
  <name>hbase.cluster.distributed</name>
  <value>true</value>
</property>
<property>
  <name>hbase.regions.server.count.min</name>
  <value>$NUM_SLAVES</value>
</property>
<property>
  <name>hbase.zookeeper.quorum</name>
  <value>$ZOOKEEPER_QUORUM</value>
</property>
<property>
  <name>hbase.regionserver.handler.count</name>
  <value>100</value>
</property>
<property>
  <name>hbase.regionserver.flushlogentries</name>
  <value>100</value>
</property>
<property>
  <name>hfile.block.cache.size</name>
  <value>0.3</value>
</property>
<property>
  <name>hbase.regionserver.global.memstore.upperLimit</name>
  <value>0.3</value>
</property>
<property>
  <name>hbase.regionserver.global.memstore.lowerLimit</name>
  <value>0.25</value>
</property>
<property>
  <name>hbase.hregion.memstore.block.multiplier</name>
  <value>4</value>
</property>
<property>
  <name>hbase.hstore.blockingStoreFiles</name>
  <value>15</value>
</property>
<property>
  <name>dfs.replication</name>
  <value>2</value>
</property>
<property>
  <name>dfs.support.append</name>
  <value>false</value>
</property>
<property>
  <name>dfs.client.block.write.retries</name>
  <value>20</value>
</property>
<property>
  <name>dfs.datanode.socket.write.timeout</name>
  <value>0</value>
</property>
<property>
  <name>zookeeper.session.timeout</name>
  <value>60000</value>
</property>
<property>
  <name>hbase.tmp.dir</name>
  <value>/mnt/hbase</value>
</property>
</configuration>
EOF
# Override JVM options
cat >> $HBASE_HOME/conf/hbase-env.sh <<EOF
export HBASE_MASTER_OPTS="-Xmx1000m -XX:+UseConcMarkSweepGC -XX:NewSize=128m -XX:MaxNewSize=128m -XX:+AggressiveOpts -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:/mnt/hbase/logs/hbase-master-gc.log"
export HBASE_REGIONSERVER_OPTS="-Xmx2000m -XX:+UseConcMarkSweepGC -XX:CMSInitiatingOccupancyFraction=88 -XX:NewSize=128m -XX:MaxNewSize=128m -XX:+AggressiveOpts -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:/mnt/hbase/logs/hbase-regionserver-gc.log"
EOF
# Configure HBase for Ganglia
cat > $HBASE_HOME/conf/hadoop-metrics.properties <<EOF
dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext
dfs.period=10
dfs.servers=$MASTER_HOST:8649
hbase.class=org.apache.hadoop.metrics.ganglia.GangliaContext
hbase.period=10
hbase.servers=$MASTER_HOST:8649
jvm.class=org.apache.hadoop.metrics.ganglia.GangliaContext
jvm.period=10
jvm.servers=$MASTER_HOST:8649
EOF

mkdir -p /mnt/hadoop/logs /mnt/hbase/logs
# FIXME: tighten ownership/perms
chmod 777 /mnt/hadoop/logs

if [ "$IS_MASTER" = "true" ]; then
  # only format on first boot
  [ ! -e /mnt/hadoop/dfs/name ] && "$HADOOP_HOME"/bin/hadoop namenode -format
  "$HADOOP_HOME"/bin/hadoop-daemon.sh start namenode
  "$HADOOP_HOME"/bin/hadoop-daemon.sh start jobtracker
  # "$HBASE_HOME"/bin/hbase-daemon.sh start master
else
    if [ "$IS_AUX" != "true" ]; then
	"$HADOOP_HOME"/bin/hadoop-daemon.sh start datanode
	"$HADOOP_HOME"/bin/hadoop-daemon.sh start tasktracker
    fi
fi

rm -f /var/ec2/ec2-run-user-data.*
