#/bin/bash

#use bash
[ "$(ps h -p "$$" -o comm)" != "bash" ] && exec bash $0 $*

#set ANSI color
nocolor='\033[0;37m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'

eclr() {
    clr=${!1}
    shift 1
    echo -e $clr"${*}"$nocolor
}

#run as root
if [ "$(id -u)" -gt 0 ]; then
    eclr red "Please run script as root\nExiting!" && exit
fi

#check if cPanel
if [ ! -f /etc/wwwacct.conf ]; then
    eclr red "Please don't run script on no-cPanel server\nExiting!" && exit
fi

temp_dir=/home/temp/wpclone$(date +%F.%T)
mkdir $temp_dir

cleanexit() {
    if [ -d $temp_dir ]; then
    rm -rf $temp_dir
    eclr red "bye!"
    exit
}

trap cleanexit SIGINT SIGTERM

#check if there are any additional users logged into ssh
logins=$(who)
logincount=$(who | wc -l)
if [ $logincount -gt 1 ]; then
    eclr red "Hey! You're not alone. Looks like someone else is on the server." && eclr cyan "$logins"
    while true; do
        eclr red "You sure we can continue (y/n?)"
        read yn
        case $yn in
            [yY]* ) break;;
            [nN]* ) eclr cyan "More luck next time." && cleanexit;;
            * ) eclr cyan "Type y or n, please.";;
        esac
    done
fi

##################################
#collect source domain information
##################################
eclr cyan "Please enter source domain: "
while read source_domain; do
    if [ -z "$source_domain" ]; then
        eclr cyan "Input was empty. Try again"
        else
            break
        fi
done
/scripts/whoowns $source_domain &> /dev/null
source_acc_exists=$? &> /dev/null

if [ $source_acc_exists -gt 0 ]; then
    eclr cyan "System suggests that domain $purple$source_domain$cyan is not set up on this server."
    while true; do
        eclr cyan "Are you sure this is correct domain name (y/n)"
        read yn
        case $yn in
            [yY]* ) break;;
            [nN]* ) eclr cyan "Please enter correct domain name: "
                    read source_domain && break;; 
            * ) eclr cyan "Type y or n, please.";;
        esac
    done
fi

#############################################
#collect source document root and validate it
#############################################
source_docroot=$(grep "^$source_domain:" /etc/userdatadomains | cut -d'=' -f9)
stat $source_docroot &> /dev/null
source_docroot_exists=$?

if [ "$source_docroot_exists" -eq 1 ]; then #let's give them one more chance
    eclr cyan "Document root for $purple$source_domain$cyan doesn't exist"
    eclr cyan "Please enter correct document root (Use tab): " && read -e -p "" source_docroot 
    stat $source_docroot &> /dev/null
    source_docroot_exists=$?
    if [ "$source_docroot_exists" -eq 1 ]; then
        eclr red "Specified directory $source_docroot doesn't exist.\nNothing to sync.\nExiting!" && cleanexit
    fi
else
    eclr cyan "System suggests that the document root for $purple$source_domain$cyan is $purple$source_docroot"
    while true; do
        eclr cyan "Is this correct (y/n)" 
        read yn
        case $yn in
            [yY]* ) break;;
            [nN]* ) unset source_docroot && eclr cyan "Please enter correct document root (use tab): " && read -e -p "" source_docroot && break;;
            * ) eclr cyan "Type y or n, please.";;
        esac
    done
    stat $source_docroot &> /dev/null
    source_docroot_exists=$?
    if [ "$source_docroot_exists" -eq 1 ]; then
        eclr red "Specified directory $source_docroot doesn't exist.\nNothing to sync.\nExiting" && cleanexit
    fi
fi

trailing=$(echo "${source_docroot: -1}")
if [ "$trailing" != "/" ]; then
    source_docroot="$source_docroot/"
fi

###########################
#collect target information
###########################
eclr cyan "Please enter target domain: " 
while read target_domain; do
    if [ -z "$target_domain" ]; then
        eclr cyan "Input was empty. Try again"
    else
        break
    fi
done
/scripts/whoowns $target_domain &> /dev/null
tar_acc_exists=$?

if [ "$tar_acc_exists" -eq 0 ]; then
    eclr red "Target domain already exists on the server,\nplease make sure that there's no content in its document root directory or\nthat you have client's permission to overwrite content if there is any."
    eclr cyan "Press any key if you want to proceed."
    read -n 1 -s -r -p ""
    target_docroot=$(grep "^$target_domain:" /etc/userdatadomains | cut -d'=' -f9)
    eclr cyan "System suggests that the document root for $purple$target_domain$cyan is $purple$target_docroot$nocolor"
    while true; do
        eclr cyan "Is this correct (y/n)"
        read yn
        case $yn in
            [yY]* ) break;;
            [nN]* ) unset target_docroot && eclr cyan "Please enter correct document root (use tab): " && read -e -p "" target_docroot && break;;
            * ) eclr cyan "Type y or n, please";;
        esac
    done
    stat $target_docroot &> /dev/null
    target_docroot_exists=$?
    if [ "$target_docroot_exists" -eq 1 ]; then
        eclr red "Specified directory $target_docroot doesn't exit.\nNo target for sync.\nExiting" && cleanexit
    fi
    account_name=$(/scripts/whoowns $target_domain)
else #create account for the target domain 
    
    eclr cyan "There is no account for this domain on the server, so we are going to create one.\nPlease enter name for new account.\n(If none is provided account name will be generated automagically) " 
    read account_name     
    if [ -z "$account_name" ]; then
        account_name=$(echo $target_domain | tr -dc '[a-z0-9]' | tr '[:upper:]' '[:lower:]' | cut -c1-16)
    fi  
    eclr cyan "Please enter password for your new account.\n(If none is provided 12 char password will be generated automagically) " 
    read account_password
    if [ -z "$account_password" ]; then
        account_password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w12 | head -1)
    fi
    /usr/local/cpanel/scripts/wwwacct $target_domain $account_name $account_password << 'EOF' &> >( while read line; do echo -e "$line"; done >> $temp_dir/acc_create.log)
y
EOF
    acc_create=$?
        if [ "$acc_create" -gt 0 ]; then
            eclr red "Account creation failed.\nPlease check $temp_dir/acc_create.log for more info.\nExiting!" && exit
        fi
    target_docroot=/home/$account_name/public_html/
fi

#recap and confirm
eclr cyan "To recap, we are cloning $purple$source_domain$cyan with document root located in $purple$source_docroot$cyan\nto domain $purple$target_domain$cyan to $purple$target_docroot$cyan directory.\nPress any key if you want to proceed."
read -n 1 -s -r -p ""

########################
#rsync data and fixperms
########################
tar_wpcnf=$target_docroot/wp-config.php
if [ -f "$tar_wpcnf" ]; then
    cp $tar_wpcnf $temp_dir/wp-config.php.bk
fi
rsync -aHP $source_docroot $target_docroot &> /dev/null
chown -hR $account_name:$account_name $target_docroot
chown -h $account_name:nobody $target_docroot

##########
#source db
##########
source_db=$(grep DB_NAME $source_docroot/wp-config.php | awk '{print$3}' | cut -d "'" -f2)
if [ -z $source_db ]; then
    unset source_db 
    source_db=$(grep DB_NAME $source_docroot/wp-config.php | awk '{print$2}' | cut -d "'" -f2)
fi 
mysqldump $source_db > $temp_dir/$source_db.sql

##########
#target db
##########
tar_acc=$(/scripts/whoowns $target_domain)
db_suffix=_wpclone
tar_db_user=$tar_acc$db_suffix
tar_db_user_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!#$%&()*+-/:;<=>?@[]_{}~' | fold -w12 | head -1)
tar_db=$tar_db_user

mysql -e "create user '$tar_db_user'@'localhost' identified by '$tar_db_user_pass'" &> /dev/null
db_usr_exist=$?
if [ "$db_usr_exist" -gt 0 ]; then
    touch $temp_dir/db_user_already_exists
fi
append_usr=1
while [ "$db_usr_exist" -gt 0 ]; do
    mysql -e "create user '$tar_db_user$append_usr'@'localhost' identified by '$tar_db_user_pass'" &> /dev/null
    db_usr_exist=$?
        if [ "$db_usr_exist" -gt 0 ]; then
            append_usr=$(($append_usr + 1 ))
                if [ "$append_usr" -eq 10 ]; then
                    break
                fi
        fi
done
if [ -f "$temp_dir/db_user_already_exists" ]; then
    tar_db_user=$tar_db_user$append_usr
fi

mysql -e "create database $tar_db" &> /dev/null
db_exist=$?
if [ "$db_exist" -gt 0 ]; then
    touch $temp_dir/db_already_exists
fi
append_db=1
while [ "$db_exist" -gt 0 ]; do
    mysql -e "create database $tar_db$append_db" &> /dev/null
    db_exist=$?
        if [ "$db_exist" -gt 0 ]; then
            append_db=$(($append_db + 1))
                if [ "$append_db" -eq 10 ]; then
                    break
                fi
        fi
done
if [ -f "$temp_dir/db_already_exists" ]; then
    tar_db=$tar_db$append_db
fi

mysql -e "grant all privileges on $tar_db.* to '$tar_db_user'@'localhost'"

/usr/local/cpanel/bin/dbmaptool $tar_acc --type mysql --dbs "$tar_db"
/usr/local/cpanel/bin/dbmaptool $tar_acc --type mysql --dbuser "$tar_db_user"

sed -i "s/$source_domain/$target_domain/g" $temp_dir/$source_db.sql
mysql $tar_db < $temp_dir/$source_db.sql
rm $temp_dir/$source_db.sql

sed -i "s/$source_db/$tar_db/g" $tar_wpcnf
sed -i "/define('DB_PASSWORD*/c\define('DB_PASSWORD', '$tar_db_user_pass');" $tar_wpcnf
sed -i "/define(' DB_PASSWORD*/c\define(' DB_PASSWORD', '$tar_db_user_pass');" $tar_wpcnf

#wrap it up
head -7 $temp_dir/acc_create.log > >( while read line; do echo "$line"; done >> $temp_dir/userinfo.txt) &> /dev/null
echo "Cloned site database: $tar_db" >> $temp_dir/userinfo.txt
echo "Cloned site database user: $tar_db_user" >> $temp_dir/userinfo.txt
echo "Cloned site database user password: $tar_db_user_pass" >> $temp_dir/userinfo.txt

eclr green "Please add content of $temp_dir/userinfo.txt to "secure note" in client's manage."
eclr green "Done cloning. Have fun!"
