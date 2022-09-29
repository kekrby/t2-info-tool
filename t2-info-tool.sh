#!/usr/bin/env sh

# Information Collection Tool for T2 Macs

set -eu

# shellcheck disable=SC3040
if ! (set -o pipefail > /dev/null 2>&1)
then
    echo Warning: pipefail is not supported by your shell, it will not be enabled
else
    # shellcheck disable=SC3040
    set -o pipefail
fi

# Helpers
mkcdir() {
    mkdir "$1"
    cd "$1"
}

temp_dir="$(mktemp -d)"

distro="$(sed -n 's/PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
model="$(cat /sys/class/dmi/id/product_name)"
kernel_ver="$(uname -r)"

firmware_dir="/lib/firmware/"
udev_rules_dir="/usr/lib/udev/rules.d/"

session_type="unknown"

if command -v loginctl > /dev/null
then
    session_type="$(loginctl show-session "$(loginctl | grep "$(whoami)" | sed "s/[[:blank:]]*\([0-9]*\) .*/\1/")" -p Type | cut -d = -f 2)"
fi

audio_config_dir=""
sound_server="none"

for server in "pipewire" "pulseaudio"
do

    if path="$(command -v "$server")"
    then
        sound_server="$path"
        break
    fi
done

case "$sound_server" in
    *pipewire)
        audio_config_dir="/usr/share/alsa-card-profile/mixer/";;
    *pulseaudio)
        audio_config_dir="/usr/share/pulseaudio/alsa-mixer/";;
esac

for logger in "journalctl" "dmesg"
do
    if command -v "$logger" > /dev/null
    then
        kernel_logger="$logger"
        break
    fi
done

case "$logger" in
    journalctl)
        kernel_logger_find="journalctl -kb -g";;
    dmesg)
        kernel_logger_find="dmesg | grep";;
esac

case "$distro" in
    NixOS*)
        firmware_dir="/run/current-system/firmware/"
        udev_rules_dir="/etc/udev/rules.d/"

        case "$sound_server" in
            *pipewire)
                audio_config_dir="$(ldd "$sound_server" | sed -n 's/[[:blank:]]*libpipewire.*=>[[:blank:]]*\(.*\)\/lib\/libpipewire.* (.*)/\1/p')/share/alsa-card-profile/mixer/";;
            *pulseaudio)
                audio_config_dir="$(dirname "$sound_server" | xargs dirname)/share/pulseaudio/alsa-mixer/";;
        esac

        # shellcheck disable=SC2016
        path="$(nix shell nixpkgs\#pciutils nixpkgs\#usbutils -c sh -c 'echo $PATH' || nix-shell -p pciutils usbutils --run 'echo $PATH' || true)"

        if [ -n "$path" ]
        then
            export PATH="$path"
        fi;;
esac

cd "$temp_dir"

mkcdir result

# General information
echo "\
Distribution: $distro
Model: $model
Kernel Version: $kernel_ver
Sound Server: $sound_server
Audio Configuration Directory: $audio_config_dir
Firmware Directory: $firmware_dir
Udev Rules Directory: $udev_rules_dir
Kernel Logger: $kernel_logger
Session Type: $session_type" > info.txt

# Kernel logs
mkcdir kernel_logs

for i in "brcmfmac" "hci0" "apple-ib" "bce.vhci" "apple.bce" "aaudio" "apple.gmux" "amdgpu" "i915"
do

    if out="$($kernel_logger_find $i: 2>&1 || true)"
    then
        echo "$out" > $i.txt
    fi
done

cd .. # kernel_logs

# Audio related stuff
mkcdir audio

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
    mkcdir files

    find "$audio_config_dir" -name "*t2*" -exec cp {} . ';'

    cd .. # files
fi

cd .. # audio

# Installed firmware
mkcdir firmware

# shellcheck disable=SC2043
for i in "brcm"
do
    sha256sum $firmware_dir/$i/* > $i.txt
done

cd .. # firmware

mkcdir misc

for command in "dkms status" "lspci -k" "lsusb -vv" "lsmod" "systemctl status bluetooth" "ip link" "mount" "rfkill" "lsblk"
do
    if command -v "$(echo "$command" | cut -d " " -f 1)" > /dev/null
    then
        name="$(echo "$command" | sed "s/ /_/g")"
        mkdir "$name"

        $command > "$name/stdout.txt" 2> "$name/stderr.txt"
    fi
done

cd .. # misc

cd .. # result

tar cf result.tar.gz result

echo Your report is in "$temp_dir/result.tar.gz"
