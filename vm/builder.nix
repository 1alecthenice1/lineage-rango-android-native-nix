# GCE build VM, booted from our own image (steps/image-build.sh builds it once
# per config change; nixos-anywhere's kexec resets C2D VMs, so no install step).
#   boot disk  -> from image family "lineage-builder" (NixOS, EFI, grows to 50 GB)
#   data disk  -> /dev/disk/by-id/scsi-0Google_PersistentDisk_src, formatted on
#                 first boot, mounted at /src (source tree, ccache, out/)
{ config, lib, pkgs, modulesPath, ... }:
let
  # AOSP expects a conventional FHS Linux; its toolchain (clang, JDK, build
  # tools) comes prebuilt in the source tree, the host only needs these
  aospEnv = pkgs.buildFHSEnv {
    name = "aosp-env";
    targetPkgs = p: with p; [
      bc binutils bison ccache curl flex gcc git git-lfs gitRepo gnumake gnupg
      gperf libxml2 lz4 lzop m4 ncurses5 nettools openssl perl pngcrush procps
      # Python modules imported by extract-utils, lineage/scripts (fbpacktool, …)
      # and the device trees
      (python3.withPackages (ps: with ps; [
        beautifulsoup4 cryptography gitpython lxml ply protobuf py7zr pyyaml requests
      ]))
      rsync schedtool squashfsTools unzip util-linux wget which xz zip
      zlib freetype fontconfig openjdk21_headless
      # /usr/include: the kernel build (Kleaf) compiles host tools such as
      # scripts/unifdef against the host's C headers, as on Ubuntu build machines
      glibc.dev linuxHeaders
    ];
    multiPkgs = p: with p; [ zlib ncurses5 ];
    runScript = "bash";
    profile = ''
      export ALLOW_NINJA_ENV=true
      export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/src/ccache
      export LC_ALL=C.UTF-8
    '';
  };
in
{
  # the image module used as intended: it builds the disk image and sets up
  # root by label + GRUB (EFI, removable path) to match it
  imports = [ "${modulesPath}/virtualisation/google-compute-image.nix" ];
  virtualisation.googleComputeImage.efi = true;
  # google-compute-config turns on OS Login (SSH tied to Google accounts via PAM);
  # we log in with our own key, and with OS Login off in the metadata its PAM
  # account check closes every session right after the key is accepted
  security.googleOsLogin.enable = lib.mkForce false;

  # /src: local NVMe SSDs if the VM has them (RAID 0 over all of them, formatted
  # at every boot — local SSDs start empty and are lost on stop/preemption),
  # else the persistent "src" disk (formatted on first use). steps/vm-create.sh
  # LOCAL_SSD=N picks. Builds are throwaway either way (no snapshots, user).
  systemd.services.src-disk = {
    description = "Prepare /src (local NVMe RAID 0 or the src disk)";
    wantedBy = [ "local-fs.target" ];
    before = [ "src.mount" ];
    after = [ "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = with pkgs; [ mdadm e2fsprogs coreutils util-linux systemd ];
    script = ''
      set -eu
      nvme=$(ls /dev/disk/by-id/google-local-nvme-ssd-* 2>/dev/null | grep -v -- -part || true)
      if [ -n "$nvme" ]; then
        n=$(echo "$nvme" | wc -l)
        if [ "$n" -gt 1 ]; then
          # reuse an array the kernel already assembled (reboot without stop);
          # its name is the kernel's (md127…), not one we choose
          dev=$(ls -d /dev/md[0-9]* 2>/dev/null | head -1 || true)
          if [ -z "$dev" ]; then
            mdadm --create /dev/md0 --level=0 --raid-devices="$n" --force --run $nvme
            udevadm settle
            dev=/dev/md0
          fi
        else
          dev=$nvme
        fi
        blkid "$dev" >/dev/null 2>&1 || mkfs.ext4 -q -F -L src -E lazy_itable_init=1,lazy_journal_init=1,root_owner=1000:100 "$dev"
      else
        dev=/dev/disk/by-id/scsi-0Google_PersistentDisk_src
        blkid "$dev" >/dev/null 2>&1 || mkfs.ext4 -q -L src -E root_owner=1000:100 "$dev"
      fi
      ln -sfn "$dev" /run/src-dev
    '';
  };
  fileSystems."/src" = {
    device = "/run/src-dev";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.requires=src-disk.service" "x-systemd.after=src-disk.service" ];
  };

  # 110 GB RAM on c2d-highcpu-56; compressed RAM swap as the only safety net
  # (the 32 GB swap file on /src went unused and cost build disk space)
  zramSwap.enable = true;

  # rootless podman for the Ubuntu build container (vm/Containerfile)
  virtualisation.podman.enable = true;
  users.users.builder.autoSubUidGidRange = true;

  environment.systemPackages = [ aospEnv pkgs.git pkgs.tmux pkgs.htop pkgs.rsync ];

  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; KbdInteractiveAuthentication = false;
                 PermitRootLogin = "prohibit-password"; };
  };
  users.users.builder = {
    isNormalUser = true;
    uid = 1000; # fixed: src-disk formats /src owned by 1000:100 (users)
    extraGroups = [ "wheel" ];
    # the build host's dedicated key for this VM (~/.ssh/gce-builder, not the GitHub key)
    openssh.authorizedKeys.keyFiles = [ ./gce-builder.pub ];
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ ./gce-builder.pub ];
  systemd.tmpfiles.rules = [ "d /src 0755 builder users -" ];
  security.sudo.wheelNeedsPassword = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "builder" ];
  };
  system.stateVersion = "26.05";
}
