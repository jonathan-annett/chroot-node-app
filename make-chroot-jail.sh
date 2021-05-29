#!/bin/bash
if [[ "$(whoami)" != "root" ]]; then
  echo "you need to be root. try again with sudo"
  exit 0
fi

if [[ "$1" == "" ]]; then
    echo "usage : sudo $(basename $0) username [ /path/to/app ] [ramdiskMB]"
    echo "   note - the username specifed should be that does not yet exist. "
    echo "         (or has been previously used if you are updating)"
    echo "        - if you don't specify /path/to/app,  /app will be assume"
    echo "           this is the the source path that will be used to create the chroot file system"
    echo "        - using 0 for ramdiskMB disables the ramdisk, and enables diagnostic mode "
    exit 0
fi

#the username
JAILED=$1
JAILROOT=/chrootjail
JAIL_SYSTEMD=${JAILED}_systemd_boot
JAIL_SYSTEMD_FILE=/etc/systemd/system/$JAIL_SYSTEMD.service

#VERBOSE=yes


if [[ "$2" != "" ]]; then
   SRC=$(realpath $2)
else 
   SRC=/app
fi


if [[ "$3" != "" ]]; then
   MB=$3
else 
   MB=1024
fi




if [[ -f $SRC/server.js ]]; then
  echo "will copy app at $SRC to chroot environment for new user $JAILED"
else
  echo "was expecting a file $SRC/server.js  - aborting"
  exit 0
fi


peer_file() {
  echo "$(dirname $(realpath $0))/$1"
}

CLONE_LIST=$(peer_file make-chroot-clone-paths)    
ETC_FILES=$(peer_file make-chroot-etc-files)    
BIN_LIST=$(peer_file make-chroot-binaries)    
EXCLUDE_LIST=$(peer_file make-chroot-exlude-squash)    


JAIL_MOUNT=${JAILED}_ramDisk


#  JAILROOT      /chrootjail
#  JAIL          /chrootjail/jailed/root     - the final root
#  JAIL_RAM      /chrootjail/jailed/ram      - holds sqfs
#  JAIL_STAGING  /chrootjail/jailed/staging    source for sqfs / root
#  JAIL_SCRIPTS  /chrootjail/jailed/scripts


JAIL=$JAILROOT/$JAILED/root
JAIL_RAM=$JAILROOT/$JAILED/ram
JAIL_PARKDIR=$JAILROOT/$JAILED/parked
JAIL_STAGING=$JAILROOT/$JAILED/staging
JAIL_SCRIPTS=$JAILROOT/$JAILED/scripts

JAIL_SQFS=$JAIL_RAM/$JAILED.sqfs
JAIL_SQFS_MOUNT=$JAIL_RAM/mnt


JAIL_CLI=${JAIL_SCRIPTS}/cli
JAIL_START=${JAIL_SCRIPTS}/start
JAIL_STOP=${JAIL_SCRIPTS}/stop
JAIL_RESTART=${JAIL_SCRIPTS}/restart
JAIL_LOGS=${JAIL_SCRIPTS}/logs
JAIL_REPL=${JAIL_SCRIPTS}/repl
JAIL_RSYNC=${JAIL_SCRIPTS}/rsync
JAIL_ADDBIN=${JAIL_SCRIPTS}/addbin
JAIL_TRACE=${JAIL_SCRIPTS}/runtime_trace
JAIL_INSTALL=${JAIL_SCRIPTS}/install
JAIL_UNINSTALL=${JAIL_SCRIPTS}/uninstall
JAIL_PARK=${JAIL_SCRIPTS}/park
JAIL_UNPARK=${JAIL_SCRIPTS}/unpark

ROOT_BINDS=(app home etc)
SQUASH_UNIONS0=(lib64 lib)
SQUASH_UNIONS1=(              bin     sbin    lib    local)
SQUASH_UNIONS=(lib64  lib  usrbin  usrsbin usrlib usrlocal)




clean_umount() {
if grep -qs "$1 " /proc/mounts; then
  [[ "$VERBOSE" == "yes" ]] && echo "note : $1 was mounted. attempting to unmount"
   umount $1
else
  [[ "$VERBOSE" == "yes" ]] && echo "note : $1 was not mounted."
fi

}

user_has_tasks() {
  local USR=$1
  [[ "$USR" == "" ]] && USR=$JAILED
  ps aux | grep -q ^$USR
}

kill_user_process() {

    TARGET="$1"
    [[ "$TARGET" == "" ]] && TARGET="$JAILED"
    
    user_has_tasks $TARGET && echo -n "terminating $TARGET tasks .."
        
    #uncermoniously nuke all processes by the jailed user 
    
    while  killall -u $TARGET 2>/dev/null
    do 
      [[ "$VERBOSE" == "yes" ]] && echo -n "."
      sleep 1 
    done
    
    echo "."

}


unmount_sqfs (){
    
    #unmount the ramdisk based union mounts
    for x in ${SQUASH_UNIONS[@]}
    do
      clean_umount $JAIL/mnt/squash/${x}.union
    done
    
    for x in ${ROOT_BINDS[@]}
    do
      clean_umount $JAIL/${x}
    done
    
    
    #unmount the mounted sqfs volume
    clean_umount $JAIL_RAM/mnt
    
}
 

unmount_all() {
    
    clean_umount $JAIL/public
    
    #unmount the unions and tmpfiles
    unmount_sqfs
    
    #unmount proc
    clean_umount $JAIL/proc
    
    #unmount the overall containing ramdisk
    clean_umount $JAIL_RAM
    
    # remove the previously created directory
    [[ -d $JAILROOT/$JAILED ]] && rm -rf $JAILROOT/$JAILED

}

remove_systemd_service () {
    
    [[ -e $JAIL_SYSTEMD_FILE ]] && systemctl stop $JAIL_SYSTEMD || systemctl stop $JAIL_SYSTEMD 2>/dev/null
    [[ -e $JAIL_SYSTEMD_FILE ]] && systemctl disable $JAIL_SYSTEMD || systemctl disable $JAIL_SYSTEMD 2>/dev/null 
    
    for X in $(ls  /etc/systemd/system/${JAIL_SYSTEMD}* /usr/lib/systemd/system/${JAIL_SYSTEMD}* 2>/dev/null)
    do 
      chmod 777 $X
      rm $X
    done
    
    systemctl daemon-reload
    systemctl reset-failed    
    
   [[ -e $JAIL_SYSTEMD_FILE ]] &&  rm $JAIL_SYSTEMD_FILE
    
}

relink() {

  chmod 555 $1

  BASE=$(basename $1)
  LINKNAME=/usr/local/bin/${JAILED}_${BASE}
  [[ -L $LINKNAME ]] && rm $LINKNAME
  
  ln -s $1 $LINKNAME
  
  echo created $BASE command 
}

remove_link() {
  BASE=$(basename $1) 
  [[ -e $1 ]] && chmod 777 $1 && rm $1 && echo removed $BASE command 
  LINKNAME=/usr/local/bin/${JAILED}_${BASE}
  [[ -L $LINKNAME ]] && rm $LINKNAME 
}


cleanup_previous() {
    remove_systemd_service
    
    kill_user_process
    
    unmount_all
    
    remove_link $JAIL_CLI
    remove_link $JAIL_START
    remove_link $JAIL_STOP
    remove_link $JAIL_RESTART
    remove_link $JAIL_LOGS
    remove_link $JAIL_REPL
    remove_link $JAIL_RSYNC
    remove_link $JAIL_ADDBIN
    remove_link $JAIL_TRACE
    remove_link $JAIL_INSTALL
    remove_link $JAIL_UNINSTALL
    remove_link $JAIL_PARK
    remove_link $JAIL_UNPARK
    
}


setup_root() {
#create mount points inside jail)
mkdir -p $JAIL/{dev,proc,etc,lib,lib64,home,app,sbin,usr,public}
mkdir -p $JAIL_STAGING/{etc,lib,lib64,home,sbin,app,usr}
mkdir -p $JAIL_STAGING/var/tmp
mkdir -p $JAIL_STAGING/usr/bin
mkdir -p $JAIL_STAGING/usr/sbin
mkdir -p $JAIL_STAGING/usr/local/bin
mkdir -p $JAIL_STAGING/home/$JAILED

chown root:root $JAIL
chown root:root $JAIL_STAGING

mknod -m 666 $JAIL/dev/null c 1 3
mknod -m 666 $JAIL/dev/random c 1 8
mknod -m 666 $JAIL/dev/urandom c 1 9
mknod -m 666 $JAIL/dev/zero c 1 5
mknod -m 666 $JAIL/dev/tty  c 5 0

chmod 0666 $JAIL/dev/{null,tty,zero}
chown root:tty $JAIL/dev/tty
}

copy_auth(){
   grep -e "^root:" -e "^${JAILED}:" /etc/$1 > $JAIL_STAGING/etc/$1
}

setup_etc(){
for FILE in $(cat $ETC_FILES ) 
do
  cp /etc/$FILE $JAIL_STAGING/etc
done


copy_auth passwd
copy_auth shadow
copy_auth group
copy_auth gshadow

chown root:root -R $JAIL_STAGING/etc/*
}

setup_libs(){
mkdir -p $JAIL_STAGING/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libnss_files.so.2 $JAIL_STAGING/usr/lib/x86_64-linux-gnu/libnss_files.so.2
cp /usr/lib/x86_64-linux-gnu/libnss_files-2.31.so $JAIL_STAGING/usr/lib/x86_64-linux-gnu/libnss_files-2.31.so

cp /usr/lib/x86_64-linux-gnu/libncursesw.so.6.2 $JAIL_STAGING/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncurses.so.6 $JAIL_STAGING/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncurses.so.6.2 $JAIL_STAGING/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncursesw.so.6 $JAIL_STAGING/usr/lib/x86_64-linux-gnu/

echo "etc clones: $CLONE_LIST"
for CLONE in $(cat $CLONE_LIST ) 
do
  [[ -d $CLONE ]] && cp -R $CLONE $JAIL_STAGING$CLONE 
  if [[ -f $CLONE ]]; then
      mkdir -p $JAIL_STAGING$(dirname $CLONE) 
      cp $CLONE $JAIL_STAGING$CLONE
  fi
done

chmod 644 $JAIL_STAGING/etc/nsswitch.conf
chmod 644 $JAIL_STAGING/etc/resolv.conf

}


copy_binary() {
    
    BINARY=$(which $1)

    if [[ "$BINARY" == "" ]]; then 
       echo "$1 is not a valid binary"
    else 
       
       [[ "$VERBOSE" == "yes" ]] &&  echo "copying $1 : $BINARY"
       cp $BINARY $JAIL_STAGING/$BINARY
       copy_dependencies $BINARY
    fi
}

# http://www.cyberciti.biz/files/lighttpd/l2chroot.txt
copy_dependencies(){
    ldd $(which $1) > ./.ldd_tmp 2>/dev/null || return 0

    FILES="$(cat ./.ldd_tmp | awk '{ print $3 }' |egrep -v ^'\(')"

    #echo "Copying shared files/libs for $1 to $JAIL_STAGING..."

    for i in $FILES
    do
        d="$(dirname $i)"
        f="$(basename $i)"
        
        [[ ! -d $JAIL_STAGING$d ]] && mkdir -p $JAIL_STAGING$d || :

        /bin/cp $i $JAIL_STAGING$d/$f
        
        [[ "$VERBOSE" == "yes" ]] && echo "$1... copying $i: $d/$f"  ||echo -n "."
    done

    sldl="$(ldd $1 | grep 'ld-linux' | awk '{ print $1}')"

    # now get sub-dir
    sldlsubdir="$(dirname $sldl)"

    if [ ! -f $JAIL_STAGING$sldl ];
    then
        [[ "$VERBOSE" == "yes" ]] && echo "$1... copying $sldl $JAIL_STAGING$sldlsubdir"  || echo -n "."
         #echo "Copying $sldl $JAIL_STAGING$sldlsubdir..."
        /bin/cp $sldl $JAIL_STAGING$sldlsubdir
    fi
}

copy_node_global () {
  LINK=$(ls `which $1` -al | cut -d \> -f 2)
  ln -s $LINK $JAIL_STAGING/usr/local/bin/$1
}

copy_binaries(){
    
ln -s ./usr/bin $JAIL/bin

for BIN in $(cat $BIN_LIST)
do
  copy_binary $BIN
done

mkdir -p $JAIL_STAGING/usr/local/lib
ln -s /usr/bin $JAIL_STAGING/usr/local/bin
#ln -s /usr/bin/init $JAIL_STAGING/sbin/init
cp -R /usr/local/lib/node_modules $JAIL_STAGING/usr/local/lib/node_modules
copy_node_global npm
copy_node_global pm2

#cp -R /var/* JAIL_STAGING/var/

rm ./.ldd_tmp
echo "."
}

setup_user(){

deluser $JAILED >/dev/null 2>/dev/null
[[ -d /home/$JAILED ]] && rm -rf /home/$JAILED
PW_TMP=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d /=+)
cat <<DEETS | adduser $JAILED >/dev/null 2>/dev/null
$PW_TMP
$PW_TMP
$JAILED





y
DEETS
PW_TMP=

cp -r /home/$JAILED/ $JAIL_STAGING/home
chown $JAILED:$JAILED $JAIL_STAGING/home/$JAILED/

chown $JAILED:$JAILED -R $JAIL_STAGING/home/$JAILED/.*

cat <<COLORS >$JAIL_STAGING/home/$JAILED/.bashrc
PS1='\[\033[1;36m\]\u\[\033[1;31m\]@\[\033[1;32m\]\h:\[\033[1;35m\]\w\[\033[1;31m\]\$\[\033[0m\] '
COLORS


}

copy_app(){


pushd $SRC >/dev/null

#run npm install as owner of app until no files are added
U=$( ls -uld . | cut -d ' ' -f 3 )
echo "while npm install | grep added ; do npm install | grep added ; done" | su $U
RESULT="$(echo "npm install || echo FAIL" | su $U)"
if [[ "$RESULT" == "FAIL" ]]; then
  exit 1 
fi
popd >/dev/null

echo "cp -R $SRC/* $JAIL_STAGING/app/"
cp -R $SRC/* $JAIL_STAGING/app/

cp $SRC/.[^.]* $JAIL_STAGING/app/

chown $JAILED:$JAILED $JAIL_STAGING/app/

chown $JAILED:$JAILED -R $JAIL_STAGING/app/.*

chown $JAILED:$JAILED -R $JAIL_STAGING/app/*


chown root:$JAILED $JAIL_STAGING/app/.env
chmod a-rwx $JAIL_STAGING/app/.env
chmod a+r   $JAIL_STAGING/app/.env
chmod g+r $JAIL_STAGING/app/.env
chmod o-r $JAIL_STAGING/app/.env

}



create_cli(){
[[ -e $JAIL_CLI ]] && chmod 777 $JAIL_CLI
cat <<BASHER > $JAIL_CLI
#!/usr/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

SHOW_SYSD=no


grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc

${JAILED}_park


if [[ "\$1" != "root" ]]; then

    if [[ "\$1" == "" ]]; then
        [[ -f $JAIL_SYSTEMD_FILE ]] && SHOW_SYSD=yes && systemctl status $JAIL_SYSTEMD --no-pager 1>&2
        CMDLINE="cd /app;pm2 status $JAILED; bash; pm2 status $JAILED;"
    else
        CMDLINE="cd /app;\$@"
    fi

    TERM=vt100 \\
    HOME=/home/$JAILED \\
    USER=$JAILED \\
    PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
    chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /usr/bin/bash -c "\$CMDLINE"

else

    if [[ "\$2" == "" ]]; then
        [[ -f $JAIL_SYSTEMD_FILE ]] && SHOW_SYSD=yes && systemctl status $JAIL_SYSTEMD --no-pager 1>&2
        CMDLINE="cd /app;pm2 status $JAILED; bash; pm2 status $JAILED;"
    else
        shift
        CMDLINE="cd /app;\$@"
    fi
    
    
    TERM=vt100 \\
    HOME=/home/$JAILED \\
    USER=$JAILED \\
    PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
    chroot $JAIL /usr/bin/bash -c "\$CMDLINE"


fi


${JAILED}_park

[[ "$SHOW_SYSD" == "yes" ]] && systemctl status $JAIL_SYSTEMD --no-pager 1>&2
SHOW_SYSD=        

BASHER

relink $JAIL_CLI

}

create_start(){
    
SCRIPT=/home/$JAILED/start.sh
[[ -e $JAIL_START ]] && chmod 777 $JAIL_START
cat <<NODER > $JAIL_START
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

${JAILED}_unpark

[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 start /app/server.js --name="$JAILED"
if [[ "\$1" == "logs" ]]; then
  echo "press ctrl-c to exit log view"
  pm2 logs $JAILED
fi
BOOT
chmod 555 $JAIL$SCRIPT

grep -qs "^proc $JAIL/proc " /proc/mounts  || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

exit 0

NODER

relink $JAIL_START


}

create_restart(){
SCRIPT=/home/$JAILED/restart.sh
[[ -e $JAIL_RESTART ]] && chmod 777 $JAIL_RESTART
cat <<NODER > $JAIL_RESTART
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi


[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 restart /app/server.js --name="$JAILED" || pm2 start /app/server.js --name="$JAILED"
if [[ "\$1" == "logs" ]]; then
   echo "press ctrl-c to exit log view"
   pm2 logs $JAILED
fi
BOOT
chmod 555 $JAIL$SCRIPT

grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

${JAILED}_park

exit 0


NODER

relink $JAIL_RESTART

}

create_stop(){
SCRIPT=/home/$JAILED/stop.sh
[[ -e $JAIL_STOP ]] && chmod 777 $JAIL_STOP
cat <<NODER > $JAIL_STOP
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi


[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 stop /app/server.js

BOOT

chmod 555 $JAIL$SCRIPT

grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

${JAILED}_park

exit 0


NODER

relink $JAIL_STOP 

}

create_logs(){
SCRIPT=/home/$JAILED/logs.sh
[[ -e $JAIL_LOGS ]] && chmod 777 $JAIL_LOGS
cat <<NODER > $JAIL_LOGS
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi


[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
echo "press ctrl-c to exit log view"
pm2 logs $JAILED --lines=

BOOT

chmod 555 $JAIL$SCRIPT

grep -qs "^proc $JAIL/proc " /proc/mounts  || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

${JAILED}_park


[[ -f $JAIL_SYSTEMD_FILE ]] && systemctl status $JAIL_SYSTEMD --no-pager 1>&2


NODER

relink  $JAIL_LOGS

}
 
create_repl(){
    
if [[ -f $JAIL_STAGING/app/node_modules/glitch-zenpoint-repl/index.js ]]; then    
SCRIPT=/home/$JAILED/repl.sh
[[ -e $JAIL_REPL ]] && chmod 777 $JAIL_REPL
cat <<NODER > $JAIL_REPL
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi


[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
/app/repl

BOOT

chmod 555 $JAIL$SCRIPT

grep -qs "^proc $JAIL/proc " /proc/mounts  || mount -t proc proc $JAIL/proc

TERM=vt100 \\
HOME=/home/$JAILED \\
USER=$JAILED \\
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[[ -f $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink $JAIL_REPL 

else

remove_link $JAIL_REPL 
fi

}

create_addbin(){
[[ -e $JAIL_ADDBIN ]] && chmod 777 $JAIL_ADDBIN
cat <<BASHER > $JAIL_ADDBIN
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi


copy_binary() {
    
    BINARY=\$(which \$1)

    if [[ "\$BINARY" == "" ]] ; then
       echo "\$1 is not a valid binary"
    else 
       cp \$BINARY $JAIL/\$BINARY
       copy_dependencies \$BINARY
    fi
}

copy_dependencies(){
    ldd \$(which \$1) > ./.ldd_tmp 2>/dev/null || return 0

    FILES="\$(cat ./.ldd_tmp | awk '{ print \$3 }' |egrep -v ^'\(')"

    #echo "Copying shared files/libs for \$1 to $JAIL..."

    for i in \$FILES
    do
        d="\$(dirname \$i)"
        f="\$(basename \$i)"
        
        [[ ! -d $JAIL\$d ]] && mkdir -p $JAIL\$d || :

        /bin/cp \$i $JAIL\$d/\$f
        
        echo -n "."
    done

    sldl="\$(ldd \$1 | grep 'ld-linux' | awk '{ print \$1}')"

    # now get sub-dir
    sldlsubdir="\$(dirname \$sldl)"

    if [ ! -f $JAIL\$sldl ];
    then
        #echo "Copying \$sldl $JAIL\$sldlsubdir..."
        /bin/cp \$sldl $JAIL\$sldlsubdir
        echo -n "."
    fi
    echo "."
}



copy_binary \$1 

BASHER

relink $JAIL_ADDBIN

}

create_runtime_trace(){

if [[ "$MB" == "0" ]]; then


SCRIPT=/home/$JAILED/tracer.sh
[[ -e $JAIL$SCRIPT ]] && chmod 777 $JAIL$SCRIPT
cat <<BASH > $JAIL$SCRIPT
#!/bin/bash
    echo "stracing: \$@"
    strace -e trace=open,openat \$@ 2>&1  | cut -d '"' -f 2  | uniq

BASH
chmod 555 $JAIL$SCRIPT
MISSING=/var/log/strace-missing
OUTPUT=/var/log/strace-output
mkdir $JAIL/var/log
touch $JAIL$MISSING
touch $JAIL$OUTPUT
chown $JAILED:$JAILED $JAIL$MISSING $JAIL$OUTPUT


[[ -e $JAIL_TRACE ]] && chmod 777 $JAIL_TRACE
cat <<LOCAL2 > $JAIL_TRACE
#!/usr/bin/bash

if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

[[ -e $JAIL/home/$JAILED/runime_tracer.sh ]] && chmod 777 $JAIL/home/$JAILED/runime_tracer.sh
cat <<INLINE > $JAIL/home/$JAILED/runime_tracer.sh
#!/bin/bash
echo "stracing: \$@"
strace -e trace=open,openat \$@ 2>> $MISSING 1>> $OUTPUT
INLINE
chmod 755 $JAIL/home/$JAILED/runime_tracer.sh

mkdir -p $JAIL/var/log
echo  "# running \$@" >$JAIL$MISSING
echo  "# running \$@" >$JAIL$OUTPUT
chown $JAILED:$JAILED $JAIL$MISSING $JAIL$OUTPUT

grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc
    
TERM=vt100 \\
HOME=/home/$JAILED \\
USER=$JAILED \\
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "/home/$JAILED/runime_tracer.sh"


cat $JAIL$OUTPUT


cp $CLONE_LIST $CLONE_LIST.tmp  
echo "" >> $CLONE_LIST.tmp

for F in \$(grep ENOENT $JAIL$MISSING | grep ^open | cut -d '"' -f 2)
do
  if [[ -e \$F ]]; then
    P=\$(realpath \$F)
    if [[ -e $JAIL\$P ]]; then
       echo "\$F exists as $JAIL\$P"
    else
       if [[ -e $JAIL\$F ]]; then
          echo "\$F exists as $JAIL\$F"
       else
          OK=0
          for CHK in \$(ls -d $JAIL/lib $JAIL/usr/lib $JAIL/usr/local/lib )
          do
             if [[ -e \$CHK\$F ]];then
                echo "\$F exists as \$CHK\$F"
                OK=1
             fi
          done     
          if [[ "\$OK" ==  "0" ]]; then
            echo "\$F not found,local= \$P"
            echo "\$F" >> $CLONE_LIST.tmp 
          fi
       fi
    fi
  fi
done

echo "" >> $CLONE_LIST.tmp

grep -v "^[[:space:]]*$" $CLONE_LIST.tmp | sort -u > $CLONE_LIST 



LOCAL2

relink  $JAIL_TRACE

else

remove_link  $JAIL_TRACE

fi


}

create_installer () {
    

[[ -e $JAIL_INSTALL ]] && chmod 777 $JAIL_INSTALL
cat <<BASHER > $JAIL_INSTALL
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 \$1
   exit 0
fi
[[ -e $JAIL_SYSTEMD_FILE ]] && echo "already installed" && exit 0

cat <<SYSTEMD > /etc/systemd/system/$JAIL_SYSTEMD.service
[Unit]
Description=$JAIL_SYSTEMD NodeJS Server

[Service]
Type=forking
WorkingDirectory=/home/$JAILED
ExecStart=/usr/local/bin/${JAILED}_start
ExecStop=/usr/local/bin/${JAILED}_stop

[Install]
WantedBy=multi-user.target

SYSTEMD

systemctl daemon-reload

${JAILED}_park
${JAILED}_start
${JAILED}_stop


systemctl start $JAIL_SYSTEMD
systemctl enable $JAIL_SYSTEMD



${JAILED}_restart

systemctl status $JAIL_SYSTEMD --no-pager 1>&2


BASHER

relink $JAIL_INSTALL

}

create_uninstaller () {
    

[[ -e $JAIL_UNINSTALL ]] && chmod 777 $JAIL_UNINSTALL
cat <<BASHER > $JAIL_UNINSTALL
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 \$1
   exit 0
fi
    [[ ! -e $JAIL_SYSTEMD_FILE ]] && echo "not installed" && exit 0

    [[ -e $JAIL_SYSTEMD_FILE ]] && systemctl stop $JAIL_SYSTEMD || systemctl stop $JAIL_SYSTEMD 2>/dev/null
    [[ -e $JAIL_SYSTEMD_FILE ]] && systemctl disable $JAIL_SYSTEMD || systemctl disable $JAIL_SYSTEMD 2>/dev/null 
    
    for X in $(ls  /etc/systemd/system/${JAIL_SYSTEMD}* /usr/lib/systemd/system/${JAIL_SYSTEMD}* 2>/dev/null)
    do 
      chmod 777 $X
      rm $X
    done
    
    systemctl daemon-reload
    systemctl reset-failed   
    
   [[ -e $JAIL_SYSTEMD_FILE ]] &&  rm $JAIL_SYSTEMD_FILE


BASHER

relink $JAIL_UNINSTALL

}


create_park () {
[[ -e $JAIL_PARK ]] && chmod 777 $JAIL_PARK
if [[ "$MB" == "0" ]]; then
cat <<BASHER > $JAIL_PARK
#!/bin/bash

BASHER
else
cat <<BASHER > $JAIL_PARK
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

cd $JAIL/mnt/squash
if [[ -d $JAIL_PARKDIR ]] ; then
    zip -fr $JAIL_PARKDIR/park.zip  \$(ls *.tmp -d) 1>&2
else
    mkdir -p $JAIL_PARKDIR
    cp $JAIL_SQFS $JAIL_PARKDIR/$JAILED.sqfs
    zip -r $JAIL_PARKDIR/park.zip  \$(ls *.tmp -d)1>&2
fi

BASHER
fi
relink $JAIL_PARK
}

create_unpark(){
[[ -e $JAIL_UNPARK ]] && chmod 777 $JAIL_UNPARK
if [[ "$MB" == "0" ]]; then
cat <<BASHER > $JAIL_UNPARK
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc


BASHER
relink $JAIL_UNPARK
else
cat <<BASHER > $JAIL_UNPARK
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 "\$@"
   exit 0
fi

ROOT_BINDS=(${ROOT_BINDS[@]})
SQUASH_UNIONS0=(${SQUASH_UNIONS0[@]})
SQUASH_UNIONS1=(${SQUASH_UNIONS1[@]})

unionize(){
    SRC=\$1
    DST=\$2
    BIN=\$3
    PREFIX=\$4
    mkdir -p $JAIL/mnt/squash/{\$BIN.tmp,\$BIN.union}
    mount -t aufs \
          -o br=$JAIL/mnt/squash/\$BIN.tmp=rw:\$SRC=ro \
          -o udba=none \
          none \
          $JAIL/mnt/squash/\$BIN.union
          

    ln -s \$PREFIX/squash/\$BIN.union \$DST 
}


grep -qs "^proc $JAIL/proc " /proc/mounts || mount -t proc proc $JAIL/proc


grep -qs "$JAIL/public " /proc/mounts || mount --bind /home/$JAILED/public $JAIL/public


if [[ -d $JAIL_PARKDIR ]] ; then


    if mount | grep "^$JAIL_MOUNT on" -q ; then
        echo "already mounted"
        exit 0
    else
        echo "remounting"
        mount -t tmpfs -o size=${MB}m $JAIL_MOUNT $JAIL_RAM
        
        
        cp $JAIL_PARKDIR/$JAILED.sqfs $JAIL_SQFS
        
        mkdir -p $JAIL_SQFS_MOUNT
        mount $JAIL_SQFS $JAIL_SQFS_MOUNT -t squashfs -o loop
        
        cd $JAIL/mnt/squash/ 
        unzip -o $JAIL_PARKDIR/park.zip
        
        for x in \${SQUASH_UNIONS0[@]}
        do
           unionize $JAIL_SQFS_MOUNT/\${x}       $JAIL/\${x} \${x}  ./mnt
        done
        
         for x in \${SQUASH_UNIONS1[@]}
         do
            unionize $JAIL_SQFS_MOUNT/usr/\${x}  $JAIL/usr/\${x} usr\${x}  ../mnt
         done
        
        
        for x in \${ROOT_BINDS[@]}
        do
          mount --bind $JAIL_STAGING/\${x} $JAIL/\${x}
        done

    fi

else
   echo "not parked"

fi



BASHER
fi

relink $JAIL_UNPARK
    
    
}

create_rsync(){
[[ -e $JAIL_RSYNC ]] && chmod 777 $JAIL_RSYNC
cat <<BASHER > $JAIL_RSYNC
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 \$1
   exit 0
fi

inotifywait -r -m -e close_write --format '%w%f' $JAIL/app | while read MODFILE
do
    echo need to rsync \$MODFILE ...
done

BASHER

relink $JAIL_RSYNC

}


unionize(){
    SRC=$1
    DST=$2
    BIN=$3
    PREFIX=$4
    mkdir -p $JAIL/mnt/squash/{$BIN.tmp,$BIN.union}
    mount -t aufs \
          -o br=$JAIL/mnt/squash/$BIN.tmp=rw:$SRC=ro \
          -o udba=none \
          none \
          $JAIL/mnt/squash/$BIN.union

    rm -rf $DST
    ln -s $PREFIX/squash/$BIN.union $DST 
}


mount_sqfs(){
    
    mount $JAIL_SQFS $JAIL_SQFS_MOUNT -t squashfs -o loop
    
    
    for x in ${SQUASH_UNIONS0[@]}
    do
       unionize $JAIL_SQFS_MOUNT/${x}       $JAIL/${x} ${x}  ./mnt
    done
    
    for x in ${SQUASH_UNIONS1[@]}
     do
        unionize $JAIL_SQFS_MOUNT/usr/${x}  $JAIL/usr/${x} usr${x}  ../mnt
     done
    
    
    for x in ${ROOT_BINDS[@]}
    do
      mount --bind $JAIL_STAGING/${x} $JAIL/${x}
    done
    
}

make_squash (){
    
   [[ -e $JAIL_SQFS ]] && rm $JAIL_SQFS
    
   mksquashfs $JAIL_STAGING $JAIL_SQFS -ef $EXCLUDE_LIST
   mkdir -p $JAIL_SQFS_MOUNT

   mount_sqfs
   
}

decode_tmp () {
[[ "$2" == "usrlocal.tmp" ]]  && realpath "$1/usr/local/$3" && return 0
[[ "$2" == "usrbin.tmp" ]]    && realpath "$1/usr/bin/$3" && return 0
[[ "$2" == "usrsbin.tmp" ]]   && realpath "$1/usr/sbin/$3" && return 0
[[ "$2" == "usrlib.tmp" ]]    && realpath "$1/usr/lib/$3" && return 0
[[ "$2" == "lib64.tmp" ]]     && realpath "$1/lib64/$3" && return 0
[[ "$2" == "lib.tmp" ]]       && realpath "$1/lib/$3" && return 0
[[ "$2" == "bin.tmp" ]]       && realpath "$1/bin/$3" && return 0
[[ "$2" == "sbin.tmp" ]]      && realpath "$1/sbin/$3" && return 0
}


patch_node(){
    
    #strictly speaking this is thepath to node on the outside of the chroot
    #however we matched that path when we made the image
    if [[ "$($JAIL_CLI root getcap `which node`)" == "" ]]; then

        $JAIL_CLI root setcap cap_net_bind_service=+ep `which node`
         
        cd $JAIL_RAM
        [[ -e temp ]] && rm -rf temp
        mkdir -p temp
        cd temp
        
        #extract the files
        unsquashfs ../zed2.sqfs
        
        #copy the changed file(s)
        BASEROOT=$(realpath ./squashfs-root)
        pushd ../../root/mnt/squash/ 2>/dev/null
        for DIR in $(ls -d *.tmp)
        do
           pushd $DIR
           for FILE in $(find . -type f 2>/dev/null)
           do
             if [[ "./.wh..wh.aufs" != "$FILE" ]]; then
                DEST=$(decode_tmp $BASEROOT $DIR $FILE)
                mkdir -p $(dirname $DEST)
                mv -v $FILE $DEST
              fi
                                                                                                                                                                                                                                                                                                                                                                                                                        done 
           popd 2>/dev/null
        done
        popd 2>/dev/null
        
        unmount_sqfs
    
        mksquashfs squashfs-root/ updated.sqfs -noappend -always-use-fragments
        
        rm ../zed2.sqfs 
        mv updated.sqfs ../zed2.sqfs    
        
        mount_sqfs
        
        cd $JAIL_RAM
        #[[ -e temp ]] && rm -rf temp
    fi
}


cleanup_previous


#create the various top level dirs
mkdir -p $JAIL
mkdir -p $JAIL_SCRIPTS

chmod 777 $JAIL

if [[ "$MB" == "0" ]]; then
  echo "RAMDISK disabled"
  JAIL_STAGING=$JAIL
else
  mkdir -p $JAIL_RAM
  mkdir -p $JAIL_STAGING
  echo "mounting $MB ramdisk $JAIL as $JAIL_MOUNT"
  mount -t tmpfs -o size=${MB}m $JAIL_MOUNT $JAIL_RAM
fi



echo "Copying files to $JAIL_STAGING"

setup_root
setup_libs
copy_binaries
setup_user
setup_etc
copy_app

create_cli
create_start
create_restart
create_stop
create_logs
create_repl
create_addbin
create_runtime_trace
create_installer
create_uninstaller

create_park
create_unpark

if [[ "$MB" == "0" ]]; then
   echo "skipping squashfs/aufs/symlinks"
else
   echo "setting up squashfs/aufs/symlinks"
   make_squash
fi

mkdir -p /home/$JAILED/public 
mkdir -p /home/$JAILED/public 
chown $JAILED:$JAILED /home/$JAILED/public
chmod a+rwx /home/$JAILED/public
chmod -R a+rw /home/$JAILED/public/*

mount --bind /home/$JAILED/public $JAIL/public


patch_node

pushd /usr/local/bin/ >/dev/null; ls --color=always -al zed2_* ; popd >/dev/null

