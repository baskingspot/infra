# An example of project-specific settings for the boxes: a NixOS module with the tools that a project needs on every box. The bench-base module imports this
# NixOS module into its box configuration (modules/bench-base/image.nix.tftpl),
# which already holds the TTL guard, nix-ld, and the benchmark sysctls.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # objdump disassembles the resolved glibc memcpy/memmove on the box.
    binutils
    perf
    jq
  ];
}
