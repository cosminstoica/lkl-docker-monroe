#!/bin/bash
#
set -x

start_tcpdump() {
        server=$1
        trace="/monroe/results/dump-$test_id-$server-$nodeid-$2.pcap.log"
        # echo "capturing packet trace to file: $trace"
        # tcpdump  -i $2  -s 150 tcp and portrange 5201-5210  -w $trace  &
        tcpdump -i $2 -s 150 not icmp and not port 5556  -w $trace  &
        sleep 0.3
}

kill_tcpdump() {
        echo "killing tcpdump"
        sleep 1
        pkill tcpdump
        pkill tcpdump
}

iptables_bypass_kernel_stack() {
  # preventive measure: drop incoming pkt to stack, but seems also affect (lkl) ourself
  # iptables -A INPUT -p tcp --source-port $port -j DROP
  # reactive measure: drop outgoing RST
  iptables -A OUTPUT -p tcp --tcp-flags RST RST -d $1 -j DROP
}

iptables_cleanup() {
  # iptables -D INPUT -p tcp --source-port $port -j DROP
  iptables -D OUTPUT -p tcp --tcp-flags RST RST -d $1 -j DROP
}

test_curl() {

  iptables_bypass_kernel_stack 130.104.230.45

  LKL_HIJACK_CONFIG_FILE=$LKL_FILE   $LKL \
   curl --resolve multipath-tcp.org:80:130.104.230.45 http://multipath-tcp.org  --connect-timeout 2

  iptables_cleanup 130.104.230.45
}

run_tcp_test() {
  echo "Run TCP test"

  error=1
  # repeat until we find a free server port
  while [[ $error -eq 1 ]]
  do
    port=$(( 5201 + RANDOM % 50))
    (eval $iperf -p $port) >> $log_tcp 2>&1
    error=$?
    sleep 2
  done

}


time=`date +%Y-%m-%d-%H%M%S`
test_id=$time

nodeid="$(cat /nodeid)"
log_file=/monroe/results/output-${time}-${nodeid}.log
log_tcp=/monroe/results/output-tcp-test.log

# Check if we are on a managed monroe node
cat /nodeid   >> $log_file 2>&1

if [ $? -eq 0 ]; then
  # echo "On Monroe node"
  cat /monroe/config
  # MONROE_NODE=true
  LKL=lkl-hijack
else
  # echo "On dev node"
  # DEVNODE=true
  LKL=lkl-hijack
  # need to create manually on dev node
  mkdir -p /monroe/results/

fi

ip addr
ip route
iface="$(ip route get 8.8.8.8|  cut -d' ' -f5| head -1)"

# ss -antop| grep 5556
# cat /etc/metadata-exporter.conf

cd /opt/monroe

# "Installing LKL package:"
apt-get install -y ./*.deb    > /dev/null

# this script creates lkl-config.json and metadata.log
./siri-test.py &

sleep 1

LKL_FILE="lkl-config.json"


ifaces="$( cat lkl-config.json |grep param| cut -f4 -d '"')"
ifcount="$(cat lkl-config.json |grep param| cut -f4 -d '"'| wc -l)"

echo "relevant ifaces: "$ifaces  >> $log_file

# tcpdump -s 150 -i $iface not icmp -w /monroe/results/dump-all  &
test_curl

inlab_server="130.104.230.97"
linode_server="139.162.73.214"


for server in $inlab_server $linode_server; do
	## Note: iperf binary won't work if renamed
	iperf="./iperf3_profile --no-delay -t 24 -i 0 -c $server --test-id $test_id "
	cmd="LKL_HIJACK_CONFIG_FILE=$LKL_FILE   $LKL  $iperf"

	IF1="$(echo $ifaces| cut -d' ' -f1)"

  run_tcp_test $iperf

  if [[ $ifcount -gt 1 ]]; then

    IF2="$(echo $ifaces| cut -d' ' -f2)"
    # echo "$IF1 $IF2"
    cmd=$cmd" -m $IF1,$IF2"
    start_tcpdump $server $IF2
  fi

  error=1

  # repeat until we find a free server port
  while [[ $error -eq 1 ]]; do

    start_tcpdump $server $IF1

    port=$(( 5201 + RANDOM % 50))

    iptables_bypass_kernel_stack $server

    command=$cmd" -p $port"
    # execute command here, output to log file
    (eval $command) >> $log_file 2>&1
    error=$?
    # iptables -L -v
    iptables_cleanup $server
    sleep 2
  done

  kill_tcpdump
done
