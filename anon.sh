#!/bin/sh

# BackBox Script for Anonymous Internet Navigation
#
# This script is intended to set up your BackBox machine to guarantee 
# anonymity through Tor. Additionally, the script takes further steps to 
# guarantee prevantion of data leakage by killing dangerous processes,
# changing MAC address and IP information and so on.
#
# Author: Raffaele Forte <raffaele@backbox.org>
# Version: 1.0
########Props to original author! This script has been modified by @ompster - nathanash.id.au for use in kali linux 2.x
# List, separated by spaces, of destinations that you do not want to be
# routed through Tor
NON_TOR="192.168.0.0/16 172.16.0.0/12"

# The UID as which Tor runs
TOR_UID="debian-tor"

# Tor TransPort
TRANS_PORT="9040"

# List, separated by spaces, of process names that should be killed
TO_KILL="chrome dropbox firefox pidgin skype thunderbird xchat"

# List, separated by spaces, of BleachBit cleaners
BLEACHBIT_CLEANERS="bash.history system.cache system.clipboard system.custom system.recent_documents system.rotated_logs system.tmp system.trash"

# Overwrite files to hide contents
OVERWRITE="true"

# The default local hostname
REAL_HOSTNAME="backbox"

# Include default options, if any
if [ -f /etc/default/backbox-anonymous ] ; then
	. /etc/default/backbox-anonymous
fi

warning() {
	echo "\n[!] WARNING! It's a simple script that avoid the most common system data"
	echo "    leaks. Your coumputer behaviour is the key to guarantee you a strong"
	echo "    privacy protection and a good anonimate."
	
	echo "\n[i] Please edit /etc/default/backbox-anonymous with your custom values."
}

# General-purpose Yes/No prompt function
ask() {
	while true; do
		if [ "${2:-}" = "Y" ]; then
			prompt="Y/n"
			default=Y
		elif [ "${2:-}" = "N" ]; then
			prompt="y/N"
			default=N
		else
			prompt="y/n"
			default=
		fi
 
		# Ask the question
		echo
		read -p "$1 [$prompt] > " REPLY
 
		# Default?
		if [ -z "$REPLY" ]; then
			REPLY=$default
		fi
 
		# Check if the reply is valid
		case "$REPLY" in
			Y*|y*) return 0 ;;
			N*|n*) return 1 ;;
		esac
	done
}

# Make sure that only root can run this script
check_root() {
	if [ $(id -u) -ne 0 ]; then
		echo "\n[!] This script must run as root\n" >&2
		exit 1
	fi
}

# Kill processes at startup
kill_process() {
	if [ "$TO_KILL" != "" ]; then
		killall -q $TO_KILL
		echo " * Killed processes to prevent leaks"
	fi
}

# Release DHCP address #Working in kali...
clean_dhcp() {
	dhclient -r
	rm -f /var/lib/dhcp/dhclient*
	echo " * DHCP address released"
}

# Change the local hostname
change_hostname() {
	
	echo

	CURRENT_HOSTNAME=$(hostname)

	clean_dhcp
	#open the common word dictionary and remove an illegal characters for use in the hostname
	RANDOM_HOSTNAME=$(shuf -n 1 /etc/dictionaries-common/words | sed -r 's/[^a-zA-Z]//g' | awk '{print tolower($0)}')

	NEW_HOSTNAME=${1:-$RANDOM_HOSTNAME}

	echo $NEW_HOSTNAME > /etc/hostname
	sed -i 's/127.0.1.1.*/127.0.1.1\t'$NEW_HOSTNAME'/g' /etc/hosts

	echo -n " * Service "
	service hostname start 2>/dev/null || echo "hostname already started"

	if [ -f "$HOME/.Xauthority" ] ; then
		su $SUDO_USER -c "xauth list | grep -v $CURRENT_HOSTNAME | cut -f1 -d\ | xargs -i xauth remove {}"
		su $SUDO_USER -c "xauth add $(xauth list | sed 's/^.*\//'$NEW_HOSTNAME'\//g')"
		echo " * X authority file updated"
	fi
	
	avahi-daemon --kill
	#works in kali!

	echo " * Hostname changed to $NEW_HOSTNAME"
}

# Change the MAC address for network interfaces
change_mac() {
	
	VAR=0
	
	while [ $VAR -eq 0 ]; do
		echo -n "Select network interfaces ["
		echo -n $(ifconfig -a | grep Ethernet | awk '{print $1}')
		read -p "] > " IFACE
		
		ifconfig -a | grep Ethernet | awk '{print $1}' | grep -q -x "$IFACE"
		
		if [ $? -ne 1 ]; then
			VAR=1
		fi
	done

	if [ "$1" = "permanent" ]; then
		NEW_MAC=$(macchanger -p $IFACE | tail -n 1 | sed 's/  //g')
		echo "\n * $NEW_MAC"
	else
		NEW_MAC=$(macchanger -A $IFACE | tail -n 1 | sed 's/  //g')
		echo "\n * $NEW_MAC"
	fi
}

# Check Tor configs
check_configs() {

	grep -q -x 'RUN_DAEMON="yes"' /etc/default/tor
	if [ $? -ne 0 ]; then
		echo "\n[!] Please add the following to your '/etc/default/tor' and restart the service:\n"
		echo ' RUN_DAEMON="yes"\n'
		exit 1
	fi

	grep -q -x 'VirtualAddrNetwork 10.192.0.0/10' /etc/tor/torrc
	VAR1=$?

	grep -q -x 'TransPort 9040' /etc/tor/torrc
	VAR2=$?

	grep -q -x 'DNSPort 53' /etc/tor/torrc
	VAR3=$?

	grep -q -x 'AutomapHostsOnResolve 1' /etc/tor/torrc
	VAR4=$?

	if [ $VAR1 -ne 0 ] || [ $VAR2 -ne 0 ] || [ $VAR3 -ne 0 ] || [ $VAR4 -ne 0 ]; then
		echo "\n[!] Please add the following to your '/etc/tor/torrc' and restart service:\n"
		echo ' VirtualAddrNetwork 10.192.0.0/10'
		echo ' TransPort 9040'
		echo ' DNSPort 53'
		echo ' AutomapHostsOnResolve 1\n'
		exit 1
	fi
}

iptables_flush() {
	iptables -F
	iptables -t nat -F
	echo " * Deleted all iptables rules"
}

# BackBox implementation of Transparently Routing Traffic Through Tor
# https://trac.torproject.org/projects/tor/wiki/doc/TransparentProxy
redirect_to_tor() {
	
	echo

	if [ ! -e /var/run/tor/tor.pid ]; then
		echo "\n[!] Tor is not running! Quitting...\n"
		exit 1
	fi

	if ! [ -f /etc/network/iptables.rules ]; then
		iptables-save > /etc/network/iptables.rules
		echo " * Saved iptables rules"
	fi

	iptables_flush

	echo -n " * Service "
	service resolvconf stop 2>/dev/null || echo "resolvconf already stopped"

	echo 'nameserver 127.0.0.1' > /etc/resolv.conf
	echo " * Modified resolv.conf to use Tor"

	iptables -t nat -A OUTPUT -m owner --uid-owner $TOR_UID -j RETURN
	iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53

	for NET in $NON_TOR 127.0.0.0/9 127.128.0.0/10; do
		iptables -t nat -A OUTPUT -d $NET -j RETURN
	done

	iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports $TRANS_PORT
	iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

	for NET in $NON_TOR 127.0.0.0/8; do
		iptables -A OUTPUT -d $NET -j ACCEPT
	done

	iptables -A OUTPUT -m owner --uid-owner $TOR_UID -j ACCEPT
	iptables -A OUTPUT -j REJECT

}

# BleachBit cleaners deletes unnecessary files to preserve privacy
do_bleachbit() {
	if [ "$OVERWRITE" = "true" ] ; then
		echo -n "\n * Deleting and overwriting unnecessary files... "
		bleachbit -o -c $BLEACHBIT_CLEANERS >/dev/null
	else
		echo -n "\n * Deleting unnecessary files... "
		bleachbit -c $BLEACHBIT_CLEANERS >/dev/null
	fi

	bleachbit -o -c $BLEACHBIT_CLEANERS >/dev/null
	echo "Done!"
}

do_start() {
	check_configs
	check_root
	
	warning

	echo "\n[i] Starting anonymous mode\n"

	echo -n " * Service "
	service network-manager stop 2>/dev/null || echo " network-manager already stopped"

	kill_process
	
	if ask "Do you want to change the MAC address?" Y; then
		change_mac
	fi
	
	if ask "Do you want to change the local hostname?" Y; then
		read -p "Type it or press Enter for a random one > " CHOICE

		if [ "$CHOICE" = "" ]; then
			change_hostname
		else
			change_hostname $CHOICE
		fi
	fi

	if ask "Do you want to transparently routing traffic through Tor?" Y; then
		redirect_to_tor
	else
		echo
	fi

	echo -n " * Service "
	service network-manager start 2>/dev/null || echo "network-manager already started"
	service tor restart
	echo
}

do_stop() {

	check_root

	echo "\n[i] Stopping anonymous mode\n"

	echo -n " * Service "
	service network-manager stop 2>/dev/null || echo " network-manager already stopped"

	iptables_flush

	if [ -f /etc/network/iptables.rules ]; then
		iptables-restore < /etc/network/iptables.rules
		rm /etc/network/iptables.rules
		echo " * Restored iptables rules"
	fi

	echo -n " * Service "
	service resolvconf start 2>/dev/null || echo "resolvconf already started"

	kill_process

	if ask "Do you want to change the MAC address?" Y; then
		change_mac permanent
	fi
	
	if ask "Do you want to change the local hostname?" Y; then
		read -p "Type it or press Enter to restore default [$REAL_HOSTNAME] > " CHOICE

		if [ "$CHOICE" = "" ]; then
			change_hostname $REAL_HOSTNAME
		else
			change_hostname $CHOICE
		fi
	else
		echo
	fi
	
	echo -n " * Service "
	service network-manager start 2>/dev/null || echo "network-manager already started"
	service tor restart

	if ask "Delete unnecessary files to preserve your privacy?" Y; then
		do_bleachbit
	fi

	echo
}

do_status() {

	echo "\n[i] Showing anonymous status\n"

	ifconfig -a | grep "encap:Ethernet" | awk '{print " * " $1, $5}'

	CURRENT_HOSTNAME=$(hostname)
	echo " * Hostname $CURRENT_HOSTNAME"
	
	HTML=$(curl -s https://check.torproject.org/?lang=en_US)
	IP=$(echo $HTML | egrep -m1 -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

	echo $HTML | grep -q "Congratulations. This browser is configured to use Tor."

	if [ $? -ne 0 ]; then
		echo " * IP $IP"
		echo " * Tor OFF\n"
		exit 3
	else
		echo " * IP $IP"
		echo " * Tor ON\n"
	fi
}

case "$1" in
	start)
		do_start
	;;
	stop)
		do_stop
	;;
	status)
		do_status
	;;
	*)
		echo "Usage: $0 {start|stop|status}" >&2
		exit 3
	;;
esac

exit 0