#!/usr/bin/env sh

# Information Collection Tool for T2 Macs

set -euo pipefail

# Helpers
qmkpushdir() {
    mkdir $1
    pushd $1 > /dev/null
}

qpopd() {
    popd > /dev/null
}

temp_dir="$(mktemp -d)"

distro="$(sed -n 's/PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
model="$(cat /sys/class/dmi/id/product_name)"
kernel_ver="$(uname -r)"

audio_config_dir=""
sound_server="none"

for server in "pipewire" "pulseaudio"
do
    path="$(command -v "$server")"

    if [ $? -eq 0 ]
    then
        sound_server="$path"
        break
    fi
done

case "$distro" in
    NixOS*)
        firmware_dir="/run/current-system/firmware"
        udev_rules_dir="/etc/udev/rules.d/"

        case "$sound_server" in
            *pipewire)
                audio_config_dir="$(ldd $sound_server | sed -n 's/[[:blank:]]*libpipewire.*=>[[:blank:]]*\(.*\)\/lib\/libpipewire.* (.*)/\1/p')/share/alsa-card-profile/mixer/";;
            *pulseaudio)
                audio_config_dir="$(command -v pulseaudio | xargs dirname | xargs dirname)/share/pulseaudio/alsa-mixer/";;
        esac;;
    *)
        firmware_dir="/lib/firmware/"
        udev_rules_dir="/usr/lib/udev/rules.d/"

        case "$sound_server" in
            *pipewire)
                audio_config_dir="/usr/share/alsa-card-profile/mixer/";;
            *pulseaudio)
                audio_config_dir="/usr/share/pulseaudio/alsa-mixer/";;
        esac;;
esac

cd $temp_dir

qmkpushdir result

# General information
echo "\
Distribution: $distro
Model: $model
Kernel Version: $kernel_ver
Sound Server: $sound_server
Audio Configuration Directory: $audio_config_dir
Firmware Directory: $firmware_dir
Udev Rules Directory: $udev_rules_dir" > info.txt

# Kernel logs
qmkpushdir dmesg

for i in "brcmfmac" "hci0" "apple-ib"
do
    if ! (dmesg | grep $i: || command -v journalctl > /dev/null && journalctl -kb 0 -g $i:) &> $i.txt
    then
        rm $i.txt
    fi
done

qpopd # dmesg

# Audio related stuff
qmkpushdir audio

cat /proc/asound/cards > asound-cards.txt
ls "$udev_rules_dir" > udev-rule-list.txt

case "$sound_server" in
    *pipewire)
        pw-dump > pw-dump.txt

        if command -v wireplumber > /dev/null
        then
            wpctl status > wpctl-status.txt
        fi;;
    *pulseaudio)
        pactl info > pactl-info.txt
        pactl list > pactl-list.txt;;
esac

if [ -d "$audio_config_dir" ]
then
    qmkpushdir files

    for file in $audio_config_dir/profile-sets/apple-t2* $audio_config_dir/paths/t2*
    do
        cat $file > $(basename $file)
    done

    qpopd # files
fi

qpopd # audio

# Installed firmware
qmkpushdir firmware

for i in "brcm"
do
    sha256sum $firmware_dir/$i/* > $i.txt
done

qpopd # firmware

qpopd # result

tar cf result.tar.gz result

echo Your report is in $temp_dir/result.tar.gz
