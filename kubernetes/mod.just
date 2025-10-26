set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/talos'
kubernetes_dir := justfile_dir() + '/kubernetes'
nodes_dir := talos_dir + '/nodes'
workspace_dir := justfile_dir()

# 1Password configuration
op_vault := "Kubernetes"
op_item_default := "talos"

[private]
default:
    just -l talos

# =============================================================================
# Validation and Preconditions
# =============================================================================

# Check if FluxCD prerequisites are met
[doc('Check FluxCD prerequisites')]
check-flux-prereqs:
    @just log info "Checking FluxCD prerequisites"
    flux check --server https://$(just talos __get-controller):6443 --pre

# =============================================================================
# Kubernetes Bootstrap
# =============================================================================

# =============================================================================
# Configuration Generation
# =============================================================================

# =============================================================================
# Cleanup Operations
# =============================================================================
