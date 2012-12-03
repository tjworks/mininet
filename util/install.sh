#!/usr/bin/env bash

# Mininet install script for Ubuntu and Debian
# Brandon Heller (brandonh@stanford.edu)

# Fail on error
set -e

# Fail on unset var usage
set -o nounset

# Location of CONFIG_NET_NS-enabled kernel(s)
KERNEL_LOC=http://www.openflow.org/downloads/mininet

# Attempt to identify Linux release

DIST=Unknown
RELEASE=Unknown
CODENAME=Unknown
ARCH=`uname -m`
if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi
if [ "$ARCH" = "i686" ]; then ARCH="i386"; fi

test -e /etc/debian_version && DIST="Debian"
grep Ubuntu /etc/lsb-release &> /dev/null && DIST="Ubuntu"
if [ "$DIST" = "Ubuntu" ] || [ "$DIST" = "Debian" ]; then
    install='sudo apt-get -y install'
    remove='sudo apt-get -y remove'
    pkginst='sudo dpkg -i'
    # Prereqs for this script
    if ! which lsb_release &> /dev/null; then
        $install lsb-release
    fi
fi
if which lsb_release &> /dev/null; then
    DIST=`lsb_release -is`
    RELEASE=`lsb_release -rs`
    CODENAME=`lsb_release -cs`
fi
echo "Detected Linux distribution: $DIST/$RELEASE/$CODENAME/$ARCH"

# Kernel params
if [ "$DIST" = "Ubuntu" ] && [ `expr $RELEASE '>=' 11.04` = 1 ]; then
    KERNEL_NAME=`uname -r`
    KERNEL_HEADERS=linux-headers-${KERNEL_NAME}
elif [ "$DIST" = "Debian" ]; then
    if [ "$CODENAME" = "Wheezy" ] || \
	[ `expr $RELEASE '>=' 7.0.0` = 1 ]; then
	KERNEL_NAME=`uname -r`
	KERNEL_HEADERS=linux-headers-${KERNEL_NAME}
    fi
else
    echo "Install.sh currently only supports Ubuntu 11+ and Debian 7+"
    exit 1
fi


# More distribution info
DIST_LC=`echo $DIST | tr [A-Z] [a-z]` # as lower case

function kernel {
    echo "Install Mininet-compatible kernel if necessary"
    sudo apt-get update
    # Might have to do this for Ubuntu netbook if that still exists...
}

# Install Mininet deps
function mn_deps {
    echo "Installing Mininet dependencies"
    $install gcc make screen psmisc xterm ssh iperf iproute telnet \
        python-setuptools python-networkx cgroup-bin ethtool help2man \
        pyflakes pylint pep8

    if [ "$DIST" = "Ubuntu" ] && [ "$RELEASE" = "10.04" ]; then
        echo "Upgrading networkx to avoid deprecation warning"
        sudo easy_install --upgrade networkx
    fi

    # Add sysctl parameters as noted in the INSTALL file to increase kernel
    # limits to support larger setups:
    sudo su -c "cat $HOME/mininet/util/sysctl_addon >> /etc/sysctl.conf"

    # Load new sysctl settings:
    sudo sysctl -p

    echo "Installing Mininet core"
    pushd ~/mininet
    sudo make install
    popd
}

# The following will cause a full OF install, covering:
# -user switch
# The instructions below are an abbreviated version from
# http://www.openflowswitch.org/wk/index.php/Debian_Install
# ... modified to use Debian Lenny rather than unstable.
function of {
    echo "Installing OpenFlow reference implementation..."
    cd ~/
    $install git-core autoconf automake autotools-dev pkg-config \
		make gcc libtool libc6-dev
    git clone git://openflowswitch.org/openflow.git
    cd ~/openflow

    # Patch controller to handle more than 16 switches
    patch -p1 < ~/mininet/util/openflow-patches/controller.patch

    # Resume the install:
    ./boot.sh
    ./configure
    make
    sudo make install

    # Remove avahi-daemon, which may cause unwanted discovery packets to be
    # sent during tests, near link status changes:
    $remove avahi-daemon

    # Disable IPv6.  Add to /etc/modprobe.d/blacklist:
    if [ "$DIST" = "Ubuntu" ]; then
        BLACKLIST=/etc/modprobe.d/blacklist.conf
    else
        BLACKLIST=/etc/modprobe.d/blacklist
    fi
    sudo sh -c "echo 'blacklist net-pf-10\nblacklist ipv6' >> $BLACKLIST"
    cd ~
}

function wireshark {
    echo "Installing Wireshark dissector..."

    sudo apt-get install -y wireshark libgtk2.0-dev

    if [ "$DIST" = "Ubuntu" ] && [ "$RELEASE" != "10.04" ]; then
        # Install newer version
        sudo apt-get install -y scons mercurial libglib2.0-dev
        sudo apt-get install -y libwiretap-dev libwireshark-dev
        cd ~
        hg clone https://bitbucket.org/barnstorm/of-dissector
        cd of-dissector/src
        export WIRESHARK=/usr/include/wireshark
        scons
        # libwireshark0/ on 11.04; libwireshark1/ on later
        WSDIR=`ls -d /usr/lib/wireshark/libwireshark* | head -1`
        WSPLUGDIR=$WSDIR/plugins/
        sudo cp openflow.so $WSPLUGDIR
        echo "Copied openflow plugin to $WSPLUGDIR"
    else
        # Install older version from reference source
        cd ~/openflow/utilities/wireshark_dissectors/openflow
        make
        sudo make install
    fi

    # Copy coloring rules: OF is white-on-blue:
    mkdir -p ~/.wireshark
    cp ~/mininet/util/colorfilters ~/.wireshark
}


# Install Open vSwitch

function ovs {
    echo "Installing Open vSwitch..."

    # Required for module build/dkms install
    $install $KERNEL_HEADERS

    # Install distribution's OVS packages
    if ! dpkg --get-selections | grep openvswitch-datapath; then
        # If you've already installed a datapath, assume you
        # know what you're doing and don't need dkms datapath.
        # Otherwise, install it.
        $install openvswitch-datapath-dkms
    fi
    if $install openvswitch-switch openvswitch-controller; then
        echo "Ignoring error installing openvswitch-controller"
    fi
    ovspresent=1

    # Switch can run on its own, but
    # Mininet should control the controller
    if [ -e /etc/init.d/openvswitch-controller ]; then
        if sudo service openvswitch-controller stop; then
            echo "Stopped running controller"
        fi
	echo "Disabling openvswitch-controller"
        sudo update-rc.d openvswitch-controller disable
    fi
}

function remove_ovs {
    pkgs=`dpkg --get-selections | grep openvswitch | awk '{ print $1;}'`
    echo "Removing existing Open vSwitch packages:"
    echo $pkgs
    if ! $remove $pkgs; then
        echo "Not all packages removed correctly"
    fi
    # For some reason this doesn't happen
    if scripts=`ls /etc/init.d/*openvswitch* 2>/dev/null`; then
        echo $scripts
        for s in $scripts; do
            s=$(basename $s)
            echo SCRIPT $s
            sudo service $s stop
            sudo rm -f /etc/init.d/$s
            sudo update-rc.d -f $s remove
        done
    fi
    echo "Done removing OVS"
}

# Install NOX with tutorial files
function nox {
    echo "Installing NOX w/tutorial files..."

    # Install NOX deps:
    $install autoconf automake g++ libtool python python-twisted \
		swig libssl-dev make
    if [ "$DIST" = "Debian" ]; then
        $install libboost1.35-dev
    elif [ "$DIST" = "Ubuntu" ]; then
        $install python-dev libboost-dev
        $install libboost-filesystem-dev
        $install libboost-test-dev
    fi
    # Install NOX optional deps:
    $install libsqlite3-dev python-simplejson

    # Fetch NOX destiny
    cd ~/
    git clone https://github.com/noxrepo/nox-classic.git noxcore
    cd noxcore
    if ! git checkout -b destiny remotes/origin/destiny ; then
        echo "Did not check out a new destiny branch - assuming current branch is destiny"
    fi

    # Apply patches
    git checkout -b tutorial-destiny
    git am ~/mininet/util/nox-patches/*tutorial-port-nox-destiny*.patch
    if [ "$DIST" = "Ubuntu" ] && [ `expr $RELEASE '>=' 12.04` = 1 ]; then
        git am ~/mininet/util/nox-patches/*nox-ubuntu12-hacks.patch
    fi

    # Build
    ./boot.sh
    mkdir build
    cd build
    ../configure
    make -j3
    #make check

    # Add NOX_CORE_DIR env var:
    sed -i -e 's|# for examples$|&\nexport NOX_CORE_DIR=~/noxcore/build/src|' ~/.bashrc

    # To verify this install:
    #cd ~/noxcore/build/src
    #./nox_core -v -i ptcp:
}

# "Install" POX
function pox {
    echo "Installing POX into $HOME/pox..."
    cd ~
    git clone https://github.com/noxrepo/pox.git
}

# Install OFtest
function oftest {
    echo "Installing oftest..."

    # Install deps:
    $install tcpdump python-scapy

    # Install oftest:
    cd ~/
    git clone git://github.com/floodlight/oftest
    cd oftest
    cd tools/munger
    sudo make install
}

# Install cbench
function cbench {
    echo "Installing cbench..."

    $install libsnmp-dev libpcap-dev libconfig-dev
    cd ~/
    git clone git://openflow.org/oflops.git
    cd oflops
    sh boot.sh || true # possible error in autoreconf, so run twice
    sh boot.sh
    ./configure --with-openflow-src-dir=$HOME/openflow
    make
    sudo make install || true # make install fails; force past this
}

function other {
    echo "Doing other setup tasks..."

    # Enable command auto completion using sudo; modify ~/.bashrc:
    sed -i -e 's|# for examples$|&\ncomplete -cf sudo|' ~/.bashrc

    # Install tcpdump and tshark, cmd-line packet dump tools.  Also install gitk,
    # a graphical git history viewer.
    $install tcpdump tshark gitk

    # Install common text editors
    $install vim nano emacs

    # Install NTP
    $install ntp

    # Set git to colorize everything.
    git config --global color.diff auto
    git config --global color.status auto
    git config --global color.branch auto

}

# Script to copy built OVS kernel module to where modprobe will
# find them automatically.  Removes the need to keep an environment variable
# for insmod usage, and works nicely with multiple kernel versions.
#
# The downside is that after each recompilation of OVS you'll need to
# re-run this script.  If you're using only one kernel version, then it may be
# a good idea to use a symbolic link in place of the copy below.
function modprobe {
    echo "Setting up modprobe for OVS kmod..."

    sudo cp $OVS_KMODS $DRIVERS_DIR
    sudo depmod -a ${KERNEL_NAME}
}

function all {
    echo "Running all commands..."
    kernel
    mn_deps
    of
    wireshark
    ovs
    # NOX-classic is deprecated, but you can install it manually if desired.
    # nox
    pox
    oftest
    cbench
    other
    echo "Done - you may wish to try 'sudo mn --test pingall' to verify."
    echo "Enjoy Mininet!"
}

# Restore disk space and remove sensitive files before shipping a VM.
function vm_clean {
    echo "Cleaning VM..."
    sudo apt-get clean
    sudo rm -rf /tmp/*

    # Remove sensistive files
    history -c  # note this won't work if you have multiple bash sessions
    rm -f ~/.bash_history  # need to clear in memory and remove on disk
    rm -f ~/.ssh/id_rsa* ~/.ssh/known_hosts
    sudo rm -f ~/.ssh/authorized_keys*

    # Clear optional dev script for SSH keychain load on boot
    rm -f ~/.bash_profile

    # Clear git changes
    git config --global user.name "None"
    git config --global user.email "None"

    # Remove mininet install script
    rm -f install-mininet.sh
}

function usage {
    printf 'Usage: %s [-abdfhknprtvwx]\n\n' $(basename $0) >&2

    printf 'This install script attempts to install useful packages\n' >&2
    printf 'for Mininet. It should (hopefully) work on Ubuntu 11.10+\n' >&2
    printf 'and Debian 7.0+. If you run into trouble, try\n' >&2
    printf 'installing one thing at a time, and looking at the \n' >&2
    printf 'specific installation function in this script.\n\n' >&2

    printf 'options:\n' >&2
    printf -- ' -a: (default) install (A)ll packages - good luck!\n' >&2
    printf -- ' -b: install controller (B)enchmark (oflops)\n' >&2
    printf -- ' -d: (D)elete some sensitive files from a VM image\n' >&2
    printf -- ' -f: install open(F)low\n' >&2
    printf -- ' -h: print this (H)elp message\n' >&2
    printf -- ' -k: install new (K)ernel\n' >&2
    printf -- ' -n: install mini(N)et dependencies + core files\n' >&2
    printf -- ' -r: remove existing Open vSwitch packages\n' >&2
    printf -- ' -t: install o(T)her stuff\n' >&2
    printf -- ' -v: install open (V)switch\n' >&2
    printf -- ' -w: install OpenFlow (w)ireshark dissector\n' >&2
    printf -- ' -x: install NO(X)-Classic OpenFlow controller\n' >&2

    exit 2
}


if [ $# -eq 0 ]
then
    all
else
    while getopts 'abdfhknprtvwx' OPTION
    do
      case $OPTION in
      a)    all;;
      b)    cbench;;
      d)    vm_clean;;
      f)    of;;
      h)    usage;;
      k)    kernel;;
      n)    mn_deps;;
      p)    pox;;
      r)    remove_ovs;;
      t)    other;;
      v)    ovs;;
      w)    wireshark;;
      x)    nox;;
      ?)    usage;;
      esac
    done
    shift $(($OPTIND - 1))
fi
