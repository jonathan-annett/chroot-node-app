#!/bin/bash

if [[ "$(whoami)" != "root" ]]; then
  echo "you need to be root. try again with sudo"
  exit 0
fi

if [[ "$1" == "" ]]; then
   echo "usage: $(basename $0) username [app source path]"
   echo "a new user will be added, and chroot entry scripts created"
   echo "WARNING - if the username exists, app processes will be terminated, and the user will be deleted"
   exit 0
fi

JAILED=$1
JAILROOT=/chrootjail

if [[ "$2" != "" ]]; then
   SRC=$2
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

JAIL=$JAILROOT/$JAILED
JAIL_MOUNT=${JAILED}_ramDisk
JAIL_CLI=$JAILROOT/${JAILED}_cli
JAIL_START=$JAILROOT/${JAILED}_start
JAIL_STOP=$JAILROOT/${JAILED}_stop
JAIL_RESTART=$JAILROOT/${JAILED}_restart
JAIL_LOGS=$JAILROOT/${JAILED}_logs
JAIL_REPL=$JAILROOT/${JAILED}_repl
JAIL_RSYNC=$JAILROOT/${JAILED}_rsync
JAIL_ADDBIN=$JAILROOT/${JAILED}_addbin


clean_umount() {
if grep -qs "$1 " /proc/mounts; then
   echo "note : $1 was mounted. attempting to unmount"
   umount $1
else
   echo "note : $1 was not mounted."
fi

}


#uncermoniously nuke all processes by the jailed user 
killall -u $JAILED 2>/dev/null
sleep 1
killall -u $JAILED 2>/dev/null
sleep 1
killall -u $JAILED 2>/dev/null
sleep 1
killall -u $JAILED 2>/dev/null


clean_umount $JAIL/mnt/squash/lib64.union
clean_umount $JAIL/mnt/squash/usrlib.union
clean_umount $JAIL/mnt/squash/lib.union
clean_umount $JAIL/mnt/squash/usrbin.union
clean_umount $JAIL/mnt/squash/usrlocal.union
clean_umount $JAIL/mnt/squash/root
clean_umount $JAIL/proc

clean_umount $JAIL



# remove the previously created directory
[[ -d $JAIL ]] && rm -rf $JAIL

[[ -f $JAIL_CLI ]] && chmod 777 $JAIL_CLI && rm $JAIL_CLI

[[ -f $JAIL_RESTART ]] && chmod 777 $JAIL_RESTART && rm $JAIL_RESTART


mkdir -p $JAIL

chmod 777 $JAIL

if [[ "$MB" == "0" ]]; then
  echo "RAMDISK disabled"
else
  echo "mounting $MB ramdisk $JAIL as $JAIL_MOUNT"
   mount -t tmpfs -o size=${MB}m $JAIL_MOUNT $JAIL
fi

echo "Copying files to $JAIL"

setup_root() {
mkdir -p $JAIL/{dev,etc,lib,lib64,home,sbin,proc}
mkdir -p $JAIL/var/tmp
mkdir -p $JAIL/usr/bin
mkdir -p $JAIL/usr/sbin
mkdir -p $JAIL/usr/local/bin
mkdir -p $JAIL/home/$JAILED

chown root.root $JAIL

mknod -m 666 $JAIL/dev/null c 1 3
mknod -m 666 $JAIL/dev/random c 1 8
mknod -m 666 $JAIL/dev/urandom c 1 9
mknod -m 666 $JAIL/dev/zero c 1 5
mknod -m 666 $JAIL/dev/tty  c 5 0

chmod 0666 $JAIL/dev/{null,tty,zero}
chown root.tty $JAIL/dev/tty
}

setup_etc(){
for FILE in $(cat make-chroot-etc-files) 
do
  cp /etc/$FILE $JAIL/etc
done
}

setup_libs(){
mkdir -p $JAIL/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libnss_files.so.2 $JAIL/usr/lib/x86_64-linux-gnu/libnss_files.so.2
cp /usr/lib/x86_64-linux-gnu/libnss_files-2.31.so $JAIL/usr/lib/x86_64-linux-gnu/libnss_files-2.31.so

cp /usr/lib/x86_64-linux-gnu/libncursesw.so.6.2 $JAIL/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncurses.so.6 $JAIL/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncurses.so.6.2 $JAIL/usr/lib/x86_64-linux-gnu/
cp /usr/lib/x86_64-linux-gnu/libncursesw.so.6 $JAIL/usr/lib/x86_64-linux-gnu/

chmod 644 $JAIL/etc/nsswitch.conf

for DIR in $(cat make-chroot-clone-paths)
do
  [ -d $DIR ] && cp -R $DIR $JAIL$DIR 
  [ -f $DIR ] && mkdir -p $JAIL$(dirname $DIR) 
  [ -f $DIR ] && cp $DIR $JAIL$DIR  
done

}

copy_binary() {
    
	BINARY=$(which $1)

    [ "$BINARY" == "" ] && echo "$1 is not a valid binary"

    [ "$BINARY" == "" ] || cp $BINARY $JAIL/$BINARY
  
    [ "$BINARY" == "" ] || copy_dependencies $BINARY
}

# http://www.cyberciti.biz/files/lighttpd/l2chroot.txt
copy_dependencies(){
    ldd $(which $1) > ./.ldd_tmp 2>/dev/null || return 0

	FILES="$(cat ./.ldd_tmp | awk '{ print $3 }' |egrep -v ^'\(')"

	#echo "Copying shared files/libs for $1 to $JAIL..."

	for i in $FILES
	do
		d="$(dirname $i)"
		f="$(basename $i)"
		
		[ ! -d $JAIL$d ] && mkdir -p $JAIL$d || :

		/bin/cp $i $JAIL$d/$f
		
		echo -n "."
	done

	sldl="$(ldd $1 | grep 'ld-linux' | awk '{ print $1}')"

	# now get sub-dir
	sldlsubdir="$(dirname $sldl)"

	if [ ! -f $JAIL$sldl ];
	then
		#echo "Copying $sldl $JAIL$sldlsubdir..."
		/bin/cp $sldl $JAIL$sldlsubdir
        echo -n "."
	fi
}

copy_node_global () {
  LINK=$(ls `which $1` -al | cut -d \> -f 2)
  ln -s $LINK $JAIL/usr/local/bin/$1
}

copy_binaries(){
    
ln -s /usr/bin $JAIL/bin

for f in $(cat make-chroot-binaries) 
do
  copy_binary $f
done

mkdir -p $JAIL/usr/local/lib
ln -s /usr/bin $JAIL/usr/local/bin
#ln -s /usr/bin/init $JAIL/sbin/init
cp -R /usr/local/lib/node_modules $JAIL/usr/local/lib/node_modules
copy_node_global npm
copy_node_global pm2

#cp -R /var/* $JAIL/var/

rm ./.ldd_tmp
}

setup_user(){

deluser $JAILED >/dev/null 2>/dev/null
[[ -d /home/$JAILED ]] && rm -rf /home/$JAILED
PW_TMP=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d /=+)
cat <<DEETS | adduser $JAILED >/dev/null 2>/dev/null
$PW_TMP
$PW_TMP






y
DEETS
PW_TMP=

cp -r /home/$JAILED/ $JAIL/home
chgrp $JAILED $JAIL/home/$JAILED/
chown $JAILED $JAIL/home/$JAILED/

chgrp $JAILED -R $JAIL/home/$JAILED/.*
chown $JAILED -R $JAIL/home/$JAILED/.*

cat <<COLORS >$JAIL/home/$JAILED/.bashrc
PS1='\[\033[1;36m\]\u\[\033[1;31m\]@\[\033[1;32m\]\h:\[\033[1;35m\]\w\[\033[1;31m\]\$\[\033[0m\] '
COLORS


}

copy_app(){

cp -R $SRC/ $JAIL/app

chgrp $JAILED $JAIL/app/
chown $JAILED $JAIL/app/

chgrp $JAILED -R $JAIL/app/.*
chown $JAILED -R $JAIL/app/.*

chgrp $JAILED -R $JAIL/app/*
chown $JAILED -R $JAIL/app/*

}

relink() {

  chmod 555 $1

  BASE=$(basename $1)
  LINKNAME=/usr/bin/$BASE
  [[ -e $LINKNAME ]] && rm $LINKNAME
  
  ln -s $1 $LINKNAME
  
  echo created $BASE command 
}

create_cli(){
[[ -e $JAIL_CLI ]] && chmod 777 $JAIL_CLI
cat <<BASHER > $JAIL_CLI
#!/usr/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc
TERM=vt100 \\
HOME=/home/$JAILED \\
USER=$JAILED \\
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /usr/bin/bash -c "cd /app;bash;"



BASHER

relink $JAIL_CLI

}

create_start(){
SCRIPT=/home/$JAILED/start.sh
[[ -e $JAIL_START ]] && chmod 777 $JAIL_START
cat <<NODER > $JAIL_START
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 start /app/server.js
echo "press ctrl-c to exit log view"
pm2 logs

BOOT
chmod 555 $JAIL$SCRIPT

[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink $JAIL_START


}

create_restart(){
SCRIPT=/home/$JAILED/restart.sh
[[ -e $JAIL_RESTART ]] && chmod 777 $JAIL_RESTART
cat <<NODER > $JAIL_RESTART
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 restart /app/server.js || pm2 start /app/server.js 
echo "press ctrl-c to exit log view"
pm2 logs

BOOT
chmod 555 $JAIL$SCRIPT

[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink $JAIL_RESTART

}

create_stop(){
SCRIPT=/home/$JAILED/stop.sh
[[ -e $JAIL_STOP ]] && chmod 777 $JAIL_STOP
cat <<NODER > $JAIL_STOP
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
pm2 stop /app/server.js

BOOT

chmod 555 $JAIL$SCRIPT

[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink $JAIL_STOP 

}

create_logs(){
SCRIPT=/home/$JAILED/logs.sh
[[ -e $JAIL_LOGS ]] && chmod 777 $JAIL_LOGS
cat <<NODER > $JAIL_LOGS
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
echo "press ctrl-c to exit log view"
pm2 logs

BOOT

chmod 555 $JAIL$SCRIPT

[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc

TERM=vt100 \
HOME=/home/$JAILED \
USER=$JAILED \
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink  $JAIL_LOGS

}
 
create_repl(){
SCRIPT=/home/$JAILED/repl.sh
[[ -e $JAIL_REPL ]] && chmod 777 $JAIL_REPL
cat <<NODER > $JAIL_REPL
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 
   exit 0
fi


[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT
cat <<BOOT > $JAIL$SCRIPT
#!/bin/bash
cd /app
/app/repl

BOOT

chmod 555 $JAIL$SCRIPT

[[ -e $JAIL/proc/1 ]] || mount -t proc proc $JAIL/proc

TERM=vt100 \\
HOME=/home/$JAILED \\
USER=$JAILED \\
PATH=/usr/local/bin:/usr/bin:/sbin:/bin:/usr/sbin \\
chroot --userspec=$JAILED:$JAILED --group=$JAILED $JAIL /bin/bash -c "$SCRIPT"
[ -f $JAIL$SCRIPT ] && chmod 777 $JAIL$SCRIPT && rm $JAIL$SCRIPT

NODER

relink $JAIL_REPL 

}

create_addbin(){
[[ -e $JAIL_ADDBIN ]] && chmod 777 $JAIL_ADDBIN
cat <<BASHER > $JAIL_ADDBIN
#!/bin/bash
if [[ "\$(whoami)" != "root" ]]; then
   sudo \$0 \$1
   exit 0
fi


copy_binary() {
    
    BINARY=\$(which \$1)

    [ "\$BINARY" == "" ] && echo "\$1 is not a valid binary"

    [ "\$BINARY" == "" ] || cp $BINARY $JAIL/\$BINARY
  
    [ "\$BINARY" == "" ] || copy_dependencies \$BINARY
}

copy_dependencies(){
    ldd \$(which \$1) > ./.ldd_tmp 2>/dev/null || return 0

    FILES="\$(cat ./.ldd_tmp | awk '{ print \$3 }' |egrep -v ^'\(')"

    #echo "Copying shared files/libs for \$1 to $JAIL..."

    for i in \$FILES
    do
        d="\$(dirname \$i)"
        f="\$(basename \$i)"
        
        [ ! -d $JAIL\$d ] && mkdir -p $JAIL\$d || :

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
}



copy_binary \$1 

BASHER

relink $JAIL_ADDBIN

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
          -o udba=reval \
          none \
          $JAIL/mnt/squash/$BIN.union

    rm -rf $DST
    ln -s $PREFIX/squash/$BIN.union $DST 
}


make_squash (){
    

   [[ -e $JAIL.usrbin.sqsh ]] && rm $JAIL.usrbin.sqsh
    
   mksquashfs $JAIL $JAIL.usrbin.sqsh
   mkdir -p $JAIL/mnt/squash/root
   mount $JAIL.usrbin.sqsh $JAIL/mnt/squash/root -t squashfs -o loop

   unionize $JAIL/mnt/squash/root/usr/bin $JAIL/usr/bin usrbin ../mnt

   unionize $JAIL/mnt/squash/root/lib $JAIL/lib lib  ./mnt

   unionize $JAIL/mnt/squash/root/usr/lib $JAIL/usr/lib usrlib ../mnt

   unionize $JAIL/mnt/squash/root/lib64 $JAIL/lib64 lib64 ./mnt
    
   unionize $JAIL/mnt/squash/root/usr/local $JAIL/usr/local usrlocal ../mnt

    
}

setup_root
setup_etc
setup_libs
copy_binaries
setup_user
copy_app

create_cli
create_start
create_restart
create_stop
create_logs
create_repl
create_addbin

make_squash


chroot $JAIL setcap cap_net_bind_service=+ep `which node`

