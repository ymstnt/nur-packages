/*
  To run:

      nix-shell maintainers/scripts/update.nix

  See https://nixos.org/manual/nixpkgs/unstable/#var-passthru-updateScript
*/
{
  package ? null,
  maintainer ? null,
  predicate ? null,
  get-script ? pkg: pkg.updateScript or null,
  path ? null,
  max-workers ? null,
  include-overlays ? false,
  keep-going ? null,
  commit ? null,
  skip-prompt ? null,
  order ? null,
}:

let
  pkgs = import <nixpkgs> (
    (
      if include-overlays == false then
        { overlays = [ ]; }
      else if include-overlays == true then
        { } # Let Nixpkgs include overlays impurely.
      else
        { overlays = include-overlays; }
    )
    // {
      config.allowAliases = false;
    }
  );

  nur-pkgs = import ../../default.nix { };

  inherit (pkgs) lib;

  # Remove duplicate elements from the list based on some extracted value. O(n^2) complexity.
  nubOn =
    f: list:
    if list == [ ] then
      [ ]
    else
      let
        x = lib.head list;
        xs = lib.filter (p: f x != f p) (lib.drop 1 list);
      in
      [ x ] ++ nubOn f xs;

  /*
    Recursively find all packages (derivations) in `pkgs` matching `cond` predicate.

    Type: packagesWithPath :: AttrPath → (AttrPath → derivation → bool) → AttrSet → List<AttrSet{attrPath :: str; package :: derivation; }>
          AttrPath :: [str]

    The packages will be returned as a list of named pairs comprising of:
      - attrPath: stringified attribute path (based on `rootPath`)
      - package: corresponding derivation
  */
  packagesWithPath =
    rootPath: cond: pkgs:
    let
      packagesWithPathInner =
        path: pathContent:
        let
          result = builtins.tryEval pathContent;

          somewhatUniqueRepresentant =
            { package, attrPath }:
            {
              updateScript = (get-script package);
              # Some updaters use the same `updateScript` value for all packages.
              # Also compare `meta.description`.
              position = package.meta.position or null;
              # We cannot always use `meta.position` since it might not be available
              # or it might be shared among multiple packages.
            };

          dedupResults = lst: nubOn somewhatUniqueRepresentant (lib.concatLists lst);
        in
        if result.success then
          let
            evaluatedPathContent = result.value;
          in
          if lib.isDerivation evaluatedPathContent then
            lib.optional (cond path evaluatedPathContent) {
              attrPath = lib.concatStringsSep "." path;
              package = evaluatedPathContent;
            }
          else if lib.isAttrs evaluatedPathContent then
            # If user explicitly points to an attrSet or it is marked for recursion, we recur.
            if
              path == rootPath
              || evaluatedPathContent.recurseForDerivations or false
              || evaluatedPathContent.recurseForRelease or false
            then
              dedupResults (
                lib.mapAttrsToList (name: elem: packagesWithPathInner (path ++ [ name ]) elem) evaluatedPathContent
              )
            else
              [ ]
          else
            [ ]
        else
          [ ];
    in
    packagesWithPathInner rootPath pkgs;

  # Recursively find all packages (derivations) in `pkgs` matching `cond` predicate.
  packagesWith = packagesWithPath [ ];

  # Recursively find all packages in `pkgs` with updateScript matching given predicate.
  packagesWithUpdateScriptMatchingPredicate =
    cond: packagesWith (path: pkg: (get-script pkg != null) && cond path pkg);

  # Recursively find all packages in `pkgs` with updateScript by given maintainer.
  packagesWithUpdateScriptAndMaintainer =
    maintainer':
    let
      maintainer =
        if !builtins.hasAttr maintainer' lib.maintainers then
          builtins.throw "Maintainer with name `${maintainer'} does not exist in `maintainers/maintainer-list.nix`."
        else
          builtins.getAttr maintainer' lib.maintainers;
    in
    packagesWithUpdateScriptMatchingPredicate (
      path: pkg:
      (
        if builtins.hasAttr "maintainers" pkg.meta then
          (
            if builtins.isList pkg.meta.maintainers then
              builtins.elem maintainer pkg.meta.maintainers
            else
              maintainer == pkg.meta.maintainers
          )
        else
          false
      )
    );

  # Recursively find all packages under `path` in `pkgs` with updateScript.
  packagesWithUpdateScript =
    path: pkgs:
    let
      prefix = lib.splitString "." path;
      pathContent = lib.attrByPath prefix null pkgs;
    in
    if pathContent == null then
      builtins.throw "Attribute path `${path}` does not exist."
    else
      packagesWithPath prefix (path: pkg: (get-script pkg != null)) pathContent;

  # Find a package under `path` in `pkgs` and require that it has an updateScript.
  packageByName =
    path: pkgs:
    let
      package = lib.attrByPath (lib.splitString "." path) null pkgs;
    in
    if package == null then
      builtins.throw "Package with an attribute name `${path}` does not exist."
    else if get-script package == null then
      builtins.throw "Package with an attribute name `${path}` does not have a `passthru.updateScript` attribute defined."
    else
      {
        attrPath = path;
        inherit package;
      };

  # List of packages matched based on the CLI arguments.
  packages =
    if package != null then
      [ (packageByName package nur-pkgs) ]
    else if predicate != null then
      packagesWithUpdateScriptMatchingPredicate predicate nur-pkgs
    else if maintainer != null then
      packagesWithUpdateScriptAndMaintainer maintainer nur-pkgs
    else if path != null then
      packagesWithUpdateScript path nur-pkgs
    else
      builtins.throw "No arguments provided.\n\n${helpText}";

  helpText = ''
    Please run:

        % nix-shell maintainers/scripts/update.nix --argstr maintainer garbas

    to run all update scripts for all packages that lists \`garbas\` as a maintainer
    and have \`updateScript\` defined, or:

        % nix-shell maintainers/scripts/update.nix --argstr package nautilus

    to run update script for specific package, or

        % nix-shell maintainers/scripts/update.nix --arg predicate '(path: pkg: pkg.updateScript.name or null == "gnome-update-script")'

    to run update script for all packages matching given predicate, or

        % nix-shell maintainers/scripts/update.nix --argstr path gnome

    to run update script for all package under an attribute path.

    You can also add

        --argstr max-workers 8

    to increase the number of jobs in parallel, or

        --argstr keep-going true

    to continue running when a single update fails.

    You can also make the updater automatically commit on your behalf from updateScripts
    that support it by adding

        --argstr commit true

    to skip prompt:

        --argstr skip-prompt true

    By default, the updater will update the packages in arbitrary order. Alternately, you can force a specific order based on the packages’ dependency relations:

        - Reverse topological order (e.g. {"gnome-text-editor", "gimp"}, {"gtk3", "gtk4"}, {"glib"}) is useful when you want checkout each commit one by one to build each package individually but some of the packages to be updated would cause a mass rebuild for the others. Of course, this requires that none of the updated dependents require a new version of the dependency.

            --argstr order reverse-topological

        - Topological order (e.g. {"glib"}, {"gtk3", "gtk4"}, {"gnome-text-editor", "gimp"}) is useful when the updated dependents require a new version of updated dependency.

            --argstr order topological

    Note that sorting requires instantiating each package and then querying Nix store for requisites so it will be pretty slow with large number of packages.
  '';

  # Transform a matched package into an object for update.py.
  packageData =
    { package, attrPath }:
    let
      updateScript = get-script package;
    in
    {
      name = package.name;
      pname = lib.getName package;
      oldVersion = lib.getVersion package;
      updateScript = map builtins.toString (lib.toList (updateScript.command or updateScript));
      supportedFeatures = updateScript.supportedFeatures or [ ];
      attrPath = updateScript.attrPath or attrPath;
    };

  # JSON file with data for update.py.
  packagesJson = pkgs.writeText "packages.json" (builtins.toJSON (map packageData packages));

  optionalArgs =
    lib.optional (max-workers != null) "--max-workers=${max-workers}"
    ++ lib.optional (keep-going == "true") "--keep-going"
    ++ lib.optional (commit == "true") "--commit"
    ++ lib.optional (skip-prompt == "true") "--skip-prompt"
    ++ lib.optional (order != null) "--order=${order}";

  args = [ packagesJson ] ++ optionalArgs;

in
pkgs.stdenv.mkDerivation {
  name = "nixpkgs-update-script";
  buildCommand = ''
    echo ""
    echo "----------------------------------------------------------------"
    echo ""
    echo "Not possible to update packages using \`nix-build\`"
    echo ""
    echo "${helpText}"
    echo "----------------------------------------------------------------"
    exit 1
  '';
  shellHook = ''
    unset shellHook # do not contaminate nested shells
    exec ${pkgs.python3.interpreter} ${./update.py} ${builtins.concatStringsSep " " args}
  '';
  nativeBuildInputs = [
    pkgs.git
    pkgs.nix
    pkgs.cacert
  ];
}
