{
  description = "Packaging proprietary or binary software for nixos";
  inputs.nixpkgs.url = "nixpkgs/nixos-22.05";
  outputs = { self, nixpkgs }: with import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
    rec {
      # git-repo package
      packages.x86_64-linux.default = pkgs.callPackage (
        { stdenv, lib, makeWrapper,
          overrideGitRepo ? null,
          overrideSSHPrefix ? null, 
          overrideHTTPPrefix ? null,
          overrideSharedGroup ? null}:
        stdenv.mkDerivation {
          name = "git-repo";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = [ makeWrapper ];
          installPhase = ''
            install -Dm755 $src/git-repo $out/bin/git-repo
            wrapProgram $out/bin/git-repo \
         		  ${lib.optionalString (overrideGitRepo != null) "--set GIT_REPO_ROOT \"${overrideGitRepo}\""} \
         		  ${lib.optionalString (overrideSSHPrefix != null) "--set CLONE_SSH_PREFIX \"${overrideSSHPrefix}\""} \
                          ${lib.optionalString (overrideHTTPPrefix != null) "--set CLONE_HTTP_PREFIX \"${overrideHTTPPrefix}\""} \
                          ${lib.optionalString (overrideSharedGroup != null) "--set GIT_SHARED_GROUP \"${overrideSharedGroup}\""}
          '';

          meta = with lib; {
            description = "simplistic git repository management in bash";
            homepage = "https://github.com/yvesf/nix-warez";
            license = licenses.cc0;
            platforms = platforms.all;
            maintainers = with maintainers; [ yvesf ];
          };
        }) {};

      # Module for easier configuration
      nixosModules.default = { config, pkgs, lib, ... }: { 
        options.programs.git-repo = {
          enable = lib.mkEnableOption "the git repo subcommand";
          dirPrefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "prefix is an absolute path. Default: /git";
          };    
          sshPrefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "sshPrefix is the URL for ssh";
          };
          httpPrefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "httpPrefix is the URL for HTTP";
          };
          sharedGroup = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "system group for shared repos";
          };
        }; 
        config = {
          environment.systemPackages = [
            (packages.x86_64-linux.default.override {
              overrideGitRepo = config.programs.git-repo.dirPrefix;
              overrideSSHPrefix = config.programs.git-repo.sshPrefix;
              overrideHTTPPrefix = config.programs.git-repo.httpPrefix;
              overrideSharedGroup = config.programs.git-repo.sharedGroup;
            })
            pkgs.gitMinimal
          ];
        }; 
      };
      
      # Tests
      checks.x86_64-linux.integration-test = with (import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system pkgs; });
        makeTest {
          name = "git-repo";
          meta = with pkgs.stdenv.lib.maintainers; {
            maintainers = [ yvesf ];
          };
          nodes = {
            machine = { pkgs, lib, config, modulesPath, ... }: {
              imports = [
                (modulesPath + "/profiles/minimal.nix")
                (modulesPath + "/config/no-x-libs.nix")
              ];
              environment.systemPackages = [ pkgs.gitMinimal packages.x86_64-linux.default pkgs.sudo ];
              users.users.jack = {
                extraGroups = [ "share" ];
                isNormalUser = true; 
              };
              users.users.alice = {
                isNormalUser = true;
              };
              users.groups.share = {};
            };
            machineWithModule = { modulesPath, ... }: {
              imports = [
                (modulesPath + "/profiles/minimal.nix")
                (modulesPath + "/config/no-x-libs.nix")
                nixosModules.default
              ];
              programs.git-repo = {
                enable = true;
                dirPrefix = "/othergit";
                sshPrefix = "ssh://foo.bar";
                httpPrefix = "http://foo.bar/git";
              };
            };
          };
          testScript = ''
            def assert_output(command, expected):
              output = machine.succeed(command).rstrip()
              assert expected == output, f"Expected: \"{expected}\". Got: \"{output}\""
            
            start_all()
            machine.wait_for_unit("default.target")
            machine.succeed("mkdir -p /git/alice && chown alice /git/alice")
            machine.succeed("mkdir -p /git/jack && chown jack /git/jack")
            machine.succeed("mkdir -p /othergit/jack && chown jack /othergit/jack")
            machineWithModule.succeed("mkdir -p /othergit")

            with subtest("command is installed"):
              result = machine.succeed("git repo help")
              assert "Subcommands of" in result
              assert "make-private" in result
            
            with subtest("test create-public"):
              machine.succeed("echo -e 'test.git\\npublic\\ny\\n' | sudo -u jack git repo create-public")
              machine.wait_for_file("/git/jack/test.git/PUBLIC")
              assert_output("cat /git/jack/test.git/description", "public")
              assert_output("stat -c %U:%G /git/jack/test.git", "jack:share")
              assert_output("stat -c %a /git/jack/test.git", "2775")
              machine.succeed("rm -rf /git/jack/test.git")
            
            with subtest("test create-private"):
              machine.succeed("echo -e 'test.git\\nprivate\\ny\\n' | sudo -u jack git repo create-private")
              assert_output("cat /git/jack/test.git/description", "private")
              assert_output("stat -c %U:%G /git/jack/test.git", "jack:users")
              assert_output("stat -c %a /git/jack/test.git", "2700")
              machine.succeed("rm -rf /git/jack/test.git")
            
            with subtest("test create-private otherroot"):
              machine.succeed("echo -e 'test.git\\nprivate\\ny\\n' | sudo -u jack GIT_REPO_ROOT=/othergit git repo create-private")
              assert_output("cat /othergit/jack/test.git/description", "private")
              machine.succeed("rm -rf /othergit/jack/test.git")
            
            with subtest("test create-shared"):
              machine.succeed("echo -e 'test.git\\nshared\\ny\\n' | sudo -u jack git repo create-shared")
              assert_output("cat /git/jack/test.git/description", "shared")
              assert_output("stat -c %U:%G /git/jack/test.git", "jack:share")
              assert_output("stat -c %a /git/jack/test.git", "2770")
              machine.succeed("rm -rf /git/jack/test.git")

            with subtest("test show"):
              machine.succeed("echo -e 'test.git\\nshared\\ny\\n' | sudo -u jack git repo create-shared")
              output = machine.succeed("sudo -u jack git repo show /git/jack/test.git")
              assert "Directory: /git/jack/test.git" in output
              machine.succeed("rm -rf /git/jack/test.git")
            
            with subtest("test list"):
              machine.succeed("echo -e 'test.git\\nshared\\ny\\n' | sudo -u jack git repo create-shared")
              output = machine.succeed("sudo -u jack git repo list")
              assert "/git/jack/test.git" in output
              assert "owner=jack group=share" in output
              assert "(shared)" in output
              machine.succeed("rm -rf /git/jack/test.git")
            
            with subtest("module configuration"):
              machineWithModule.succeed("echo -e 'test.git\\nshared\\ny\\n' | git repo create-shared")
              output = machineWithModule.succeed("git repo list")
              assert "/othergit/root/test.git" in output
              output = machineWithModule.succeed("git repo show /othergit/root/test.git")
              assert "git clone 'ssh://foo.bar/othergit/root/test.git'" in output
              assert "git remote set-url origin 'ssh://foo.bar/othergit/root/test.git" in output
          '';
        };
    };
}
