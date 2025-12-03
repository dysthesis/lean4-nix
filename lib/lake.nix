{
  pkgs,
  lib,
  stdenv,
  lean,
  runCommand,
  git,
}: let
  capitalize = s: let
    first = lib.toUpper (builtins.substring 0 1 s);
    rest = builtins.substring 1 (-1) s;
  in
    first + rest;
  importLakeManifest = manifestFile: let
    manifest = lib.importJSON manifestFile;
  in
    lib.warnIf (manifest.version != "1.1.0") ("Unknown version: " + builtins.toString manifest.version) manifest;
  # A wrapper around `mkDerivation` which sets up the lake manifest
  mkLakeDerivation = args @ {
    name,
    src,
    deps ? {},
    ...
  }: let
    manifest = importLakeManifest "${src}/lake-manifest.json";
    mkOneManifest = {
      name,
      inherited ? false,
      ...
    }: rec {
      inherit name inherited;
      # We set the entry as `git`, so that Lake will clone it to the Nix store
      # to the build directory, where it has read/write access.
      type = "git";
      url = deps.${name};
      rev =
        lib.removeSuffix "\n"
        (builtins.readFile "${deps.${name}}/commit-hash");
    };
    # create a surrogate manifest
    replaceManifest =
      pkgs.writers.writeJSON "lake-manifest.json"
      (lib.setAttr manifest "packages"
        (builtins.map mkOneManifest manifest.packages));

    mkFakeGitRepo = name: src:
      runCommand "${name}-fake-git" {
        buildInputs = [git];
      } ''
        export HOME=$TMPDIR
        mkdir -pv $out
        cd $out/
        cp -r ${src}/* .
        git init
        git add .
        export GIT_AUTHOR_NAME="nix"
        export GIT_AUTHOR_EMAIL="nix@example.com"
        export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
        export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
        export GIT_AUTHOR_DATE="1970-01-01T00:00:00Z"
        export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
        git commit -m "Snapshot for Nix"
        git rev-parse HEAD > commit-hash
      '';

    builtPkg = stdenv.mkDerivation (
      {
        buildInputs = [git lean.lean-all];

        configurePhase = ''
          rm lake-manifest.json
          ln -s ${replaceManifest} lake-manifest.json
        '';

        buildPhase = ''
          export HOME=$TMPDIR
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
              name: path: "git config --global --add safe.directory ${path}/.git"
            )
            deps)}
          lake build
        '';
        installPhase = ''
          mkdir -p $out/
          mv * $out/
          mv .lake $out/
        '';
      }
      // (builtins.removeAttrs args ["deps"])
    );
  in
    mkFakeGitRepo name builtPkg;
  # Builds a Lean package by reading the manifest file.
  mkPackage = args @ {
    # Path to the source
    src,
    # Path to the `lake-manifest.json` file
    manifestFile ? "${src}/lake-manifest.json",
    # Root module
    roots ? null,
    # Static library dependencies
    staticLibDeps ? [],
    ...
  }: let
    manifest = importLakeManifest manifestFile;

    roots =
      args.roots or [(capitalize manifest.name)];

    depSources = builtins.listToAttrs (builtins.map (info: let
        src = builtins.fetchGit {
          inherit (info) url rev;
          shallow = true;
        };
      in {
        inherit (info) name;
        value = src;
      })
      manifest.packages);
    # construct dependency name map
    flatDeps =
      lib.mapAttrs (
        _name: src: let
          manifest = importLakeManifest "${src}/lake-manifest.json";
          deps = builtins.map ({name, ...}: name) manifest.packages;
        in
          deps
      )
      depSources;

    # Build all dependencies
    manifestDeps = builtins.listToAttrs (builtins.map (info: {
        inherit (info) name;
        value = mkLakeDerivation {
          inherit (info) name url;
          src = depSources.${info.name};
          deps = builtins.listToAttrs (builtins.map (name: {
              inherit name;
              value = manifestDeps.${name};
            })
            flatDeps.${info.name});
        };
      })
      manifest.packages);
  in
    mkLakeDerivation {
      inherit src;
      inherit (manifest) name;
      deps = manifestDeps;
      nativeBuildInputs = staticLibDeps;
      buildPhase =
        args.buildPhase
        or ''
          lake build #${builtins.concatStringsSep " " roots}
        '';
      installPhase =
        args.installPhase
        or ''
          mkdir $out
          if [ -d .lake/build/bin ]; then
            mv .lake/build/bin $out/
          fi
          if [ -d .lake/build/lib ]; then
            mv .lake/build/lib $out/
          fi
        '';
    };
in {
  inherit mkLakeDerivation mkPackage;
}
