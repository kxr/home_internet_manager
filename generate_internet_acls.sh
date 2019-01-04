#!/bin/bash

INTERNET_ALLOWED_HOSTS="/root/internet_allowed_hosts.csv"

DHCP_MAC_FILE="/etc/dnsmasq.d/dhcp-ips.conf"
LAN_HOSTS_FILE="/etc/hosts.lan"
CONF_BACKUP="/root/backups/mac-ip-list"
FIREWALLD_ZONE="internet"
TIME_STAMP="$(date +%Y%m%d%H%M)"

#Backup existing conf files
cp -a "$INTERNET_ALLOWED_HOSTS" "$CONF_BACKUP/internet_allowed_hosts_backup.$TIME_STAMP"


# Clear existing conf files
mv $DHCP_MAC_FILE /tmp/
mv $LAN_HOSTS_FILE /tmp/

CURR_FW_MACS=()
ADDING_MACS=()
ADDING_IPS=()
ADD_C=0
DEL_C=0

for curr_fw_mac in $(firewall-cmd --list-sources --zone="$FIREWALLD_ZONE")
do
        CURR_FW_MACS+=($curr_fw_mac)
done

IFS='
'
for line in $(cat $INTERNET_ALLOWED_HOSTS | grep -v '^#\|^$')
do
        #Split the line into proper variables
        genr_name=$(echo $line | tr -d '\t' | cut -d',' -f1 | tr -d ' ')
        host_names=$(echo $line | tr -d '\t' | cut -d',' -f2 | tr -d ' ')
        p_host_name=$(echo $host_names | cut -d'|' -f1)
        mac_address=$(echo $line | tr -d '\t' | cut -d',' -f3 | tr -d ' ' | tr a-z A-Z)
        ip_address=$(echo $line | tr -d '\t' | cut -d',' -f4 | tr -d ' ')


        # Duplicate check
        if [[ " ${ADDING_MACS[@]} " =~ " ${mac_address} " ]]
        then
                echo "WARNING: Duplicate MAC Address ($mac_address) found, Ignoring following entry:"
                echo "    $line"
                continue
        elif [[ " ${ADDING_IPS[@]} " =~ " ${ip_address} " ]]
        then
                echo "WARNING: Duplicate IP Address ($ip_address) found, Ignoring following entry:"
                echo "    $line"
                continue
        else
                ADDING_MACS+=($mac_address)
                if [ "$ip_address" != "dhcp" -a "$ip_address" != "DHCP" -a "$ip_address" != "" ]
                then
                        ADDING_IPS+=($ip_address)
                fi
        fi

        #Generate the dhcp configuration line for this entry
        if [ "$ip_address" == "dhcp" -o "$ip_address" == "DHCP" -o "$ip_address" == "" ]
        then
                echo "dhcp-host=${mac_address},${p_host_name}.kxr.int,1d" >> $DHCP_MAC_FILE
        else
                echo "dhcp-host=${mac_address},${p_host_name}.kxr.int,${ip_address},1d" >> $DHCP_MAC_FILE
                echo "${ip_address} $(echo $host_names | sed 's/|/.kxr.int /g')" >> $LAN_HOSTS_FILE
        fi

        if [[ ! ( " ${CURR_FW_MACS[@]} " =~ " ${mac_address} " ) ]]
        then
                ADD_C=$(( ADD_C + 1 ))
                echo "ADDING: MAC Address $curr_fw_mac (${p_host_name}.kxr.int)..."
                firewall-cmd -q --zone="$FIREWALLD_ZONE" --add-source="$mac_address"
        fi

done


# Remove MACS from firewalld if an entry is removed
for curr_fw_mac in "${CURR_FW_MACS[@]}"
do
        if [[ ! ( " ${ADDING_MACS[@]} " =~ " ${curr_fw_mac} " ) ]]
        then
                DEL_C=$(( DEL_C + 1 ))
                rem_host=$(cat "/tmp/dhcp-ips.conf" | grep -w "$curr_fw_mac" | cut -d ',' -f2)
                echo "REMOVING: MAC Address $curr_fw_mac ($rem_host) ..."
                firewall-cmd -q --zone="$FIREWALLD_ZONE" --remove-source="$curr_fw_mac"
        fi
done

firewall-cmd -q --runtime-to-permanent
if [ "$?" != "0" ]
then
        echo "PANIC:   FIREWALLD --runtime-to-permanent"
        echo "PANIC:   INTERNET MIGHT NOT BE WORKING FOR LAN CLIENTS"
        echo "PANIC:   CHECK WHY --runtime-to-permanent FAILED"
fi

systemctl restart dnsmasq

# Check dnsmasq
systemctl is-active dnsmasq > /dev/null
if [ "$?" != "0" ]
then
        journalctl --since '2 min ago' -u dnsmasq > "/tmp/dnsmasq-debug-${TIME_STAMP}.log"
        mv "$DHCP_MAC_FILE" "/tmp/dnsmasq-wrong-config-${TIME_STAMP}.conf"
        mv "/tmp/dhcp-ips.conf" "$DHCP_MAC_FILE"
        echo "ERROR:   Some thing went wrong, dnsmasq didn't start up with new entries"
        echo "RESTORE: Going back to last know working configuration"
        echo "DEBUG:   Check this log file for errors: /tmp/dnsmasq-debug-${TIME_STAMP}.log"
        echo "DEBUG:   The configuration file that caused the error is here: /tmp/dnsmasq-wrong-config-${TIME_STAMP}.conf"

        systemctl restart dnsmasq

        # Check dnsmasq again
        systemctl is-active dnsmasq > /dev/null
        if [ "$?" != "0" ]
        then
                echo "PANIC:   EVEN THE LAST KNOW CONFIGURATION FAILED"
                echo "PANIC:   INTERNET WILL NOT FOR LAN CLIENTS"
                echo "PANIC:   CHECK dnsmasq CONFIGURATION"
        else
                echo "SUCCESS: dnsmasq started with last know configuration"
        fi
fi

echo -n "Done"
if [ "$ADD_C" == "0" -a "$DEL_C" == "0" ]
then
        echo " (Nothing changed)"
else
        echo " ( $ADD_C Additions and $DEL_C Deletions)"
fi
