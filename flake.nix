{
  # LineageOS for the Pixel 10 Pro Fold (rango), built in the cloud, signed at home.
  # Build host: NixOS on an x86_64 Google Compute Engine VM booted from our own
  # image (adapted from github.com/1alecthenice1/gcenixos, which installed NixOS
  # with disko on an ARM T2A VM). LineageOS only builds on x86_64.
  description = "LineageOS rango: GCE build VM + build/sign scripts";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }: {
    nixosConfigurations.builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./vm/builder.nix ];
    };
    # raw GCE image (tar.gz with disk.raw), built on a Debian VM by steps/image-build.sh
    packages.x86_64-linux.image = self.nixosConfigurations.builder.config.system.build.googleComputeImage;
  };
}
