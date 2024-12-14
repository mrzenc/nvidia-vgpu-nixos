/*
 Copyright (c) 2003-2024 Eelco Dolstra and the Nixpkgs/NixOS contributors

 Original source code:
 https://github.com/NixOS/nixpkgs/blob/54fee3a7e34a613aabc6dece34d5b7993183369c/pkgs/os-specific/linux/nvidia-x11/generic.nix
*/
{ version
, settingsSha256 ? null
, settingsVersion ? version
, persistencedSha256 ? null
, persistencedVersion ? version
, vgpuPatcher ? null
, useGLVND ? true
, useProfiles ? true
, preferGtk2 ? false
, settings32Bit ? false
, useSettings ? true
, usePersistenced ? true
, ibtSupport ? false

, prePatch ? null
, postPatch ? null
, patchFlags ? null
, patches ? [ ]
, preInstall ? null
, postInstall ? null
, broken ? false
}@args:

{ lib
, stdenv
, callPackage
, pkgs
, pkgsi686Linux
, fetchurl
, fetchzip
, kernel
, bbe
, perl
, gawk
, coreutils
, pciutils
, nukeReferences
, makeWrapper
, which
, libarchive
, jq

, src
, patcherArgs ? ""
, guest ? false
, merged ? false
, # don't include the bundled 32-bit libraries on 64-bit platforms,
  # even if it’s in downloaded binary
  disable32Bit ? false
  # Whether to extract the GSP firmware, datacenter drivers needs to extract the
  # firmware
, firmware ? false
}:

with lib;

assert useSettings -> settingsSha256 != null;
assert usePersistenced -> persistencedSha256 != null;

let
  guiBundled = guest || merged;
  i686bundled = !disable32Bit && guiBundled;

  patcher = if vgpuPatcher == null then null else (vgpuPatcher src);

  # TODO: use graphics-related libraries for merged drivers only
  libPathFor = pkgs: lib.makeLibraryPath (with pkgs; [
    libdrm
    xorg.libXext
    xorg.libX11
    xorg.libXv
    xorg.libXrandr
    xorg.libxcb
    zlib
    stdenv.cc.cc
    wayland
    mesa
    libGL
    openssl
    dbus # for nvidia-powerd
  ]);

  self = stdenv.mkDerivation {
    name = "nvidia-vgpu-${version}-${kernel.version}";

    builder = ./builder.sh;

    system = "x86_64";

    inherit src patcher patcherArgs patches;
    inherit prePatch postPatch patchFlags;
    inherit preInstall postInstall;
    inherit version useGLVND useProfiles;
    inherit guiBundled i686bundled;

    postFixup = optionalString (!guest) ''
      # wrap sriov-manage
      wrapProgram $bin/bin/sriov-manage \
        --set PATH ${lib.makeBinPath [
          coreutils
          pciutils
          gawk
        ]}
    '';

    outputs = [ "out" "bin" ]
      ++ optional i686bundled "lib32"
      ++ optional firmware "firmware";
    outputDev = "bin";

    kernel = kernel.dev;
    kernelVersion = kernel.modDirVersion;

    makeFlags = kernel.makeFlags ++ [
      "IGNORE_PREEMPT_RT_PRESENCE=1"
      "NV_BUILD_SUPPORTS_HMM=1"
      "SYSSRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
      "SYSOUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    ];

    hardeningDisable = [ "pic" "format" ];

    dontStrip = true;
    dontPatchELF = true;

    libPath = libPathFor pkgs;
    libPath32 = optionalString i686bundled (libPathFor pkgsi686Linux);

    buildInputs = optional (!guest) pciutils;
    nativeBuildInputs = [ perl nukeReferences makeWrapper which libarchive jq kernel.moduleBuildDependencies ]
      ++ optional (!guest) bbe;

    disallowedReferences = [ kernel.dev ];

    passthru =
      let
        fetchFromGithubOrNvidia = { owner, repo, rev, ... }@args:
          let
            args' = builtins.removeAttrs args [ "owner" "repo" "rev" ];
            baseUrl = "https://github.com/${owner}/${repo}";
          in
          fetchzip (args' // {
            urls = [
              "${baseUrl}/archive/${rev}.tar.gz"
              "https://download.nvidia.com/XFree86/${repo}/${repo}-${rev}.tar.bz2"
            ];
            # github and nvidia use different compression algorithms,
            #  use an invalid file extension to force detection.
            extension = "tar.??";
          });
      in
      {
        settings =
          if useSettings then
            (if settings32Bit then pkgsi686Linux.callPackage else callPackage)
              (import (pkgs.path + "/pkgs/os-specific/linux/nvidia-x11/settings.nix") self settingsSha256)
              {
                withGtk2 = preferGtk2;
                withGtk3 = !preferGtk2;
                fetchFromGitHub = fetchFromGithubOrNvidia;
              } else { };
        persistenced =
          if usePersistenced then
            mapNullable
              (hash: callPackage
                (import (pkgs.path + "/pkgs/os-specific/linux/nvidia-x11/persistenced.nix") self hash) {
                fetchFromGitHub = fetchFromGithubOrNvidia;
              })
              persistencedSha256
          else { };
        fabricmanager = (throw ''
          NVIDIA datacenter drivers are not compatible with vGPU drivers.
          Did you set `hardware.nvidia.datacenter.enable` to `true`?
        '');
        inherit persistencedVersion settingsVersion;
        compressFirmware = false;
        ibtSupport = ibtSupport || (lib.versionAtLeast version "530");
        vgpuPatcher = patcher;
      };

    meta = {
      platforms = [ "x86_64-linux" ]; # for compatibility with persistenced.nix and settings.nix
      priority = 4; # resolves collision with xorg-server's "lib/xorg/modules/extensions/libglx.so"
    };
  };

in
self
