set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

default_schematic := "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba" # Default Talos schematic ID (vanilla)
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

# Check if talconfig.yaml exists
[private]
__check-talconfig-exists:
    @test -f {{ talos_dir }}/talconfig.yaml || (just log error "talconfig.yaml not found in {{ talos_dir }}" && exit 1)

# Check if talsecret.yaml configuration exists
[private]
__check-secrets-exists:
    @test -f {{ talos_dir }}/talsecret.yaml || (just log error "talsecret.yaml not found in {{ talos_dir }}" && exit 1)

# Check if node is a controller
[private]
__is-controller node:
    just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

# Get node IPs from talconfig.yaml as space-separated string
[private]
__get-node-ips:
    @yq '.nodes[].ipAddress' {{ talos_dir }}/talconfig.yaml | tr '\n' ' ' | sed 's/ $//'

# Get the first controller endpoint from talosconfig
[private]
__get-controller:
    @talosctl config --talosconfig {{ nodes_dir }}/talosconfig info -o yaml | yq -e '.endpoints[0]'

# Check if any nodes are already in secured/bootstrapped state
[private]
__check-nodes-not-bootstrapped:
    #!/bin/bash
    set -euo pipefail
    
    # Get node IPs and convert to array
    node_ips=($(just talos __get-node-ips))
    
    secured_nodes=()
    
    for ip in "${node_ips[@]}"; do
        # Try to connect in insecure mode - if it fails with certificate error, node is secured
        if talosctl version --insecure -n "${ip}" >/dev/null 2>&1; then
            continue  # Node accepts insecure connections (not yet bootstrapped)
        else
            # Check if the error is specifically about certificate requirements
            error_output=$(talosctl version --insecure -n "${ip}" 2>&1 || true)
            if echo "$error_output" | grep -q "certificate required"; then
                secured_nodes+=("${ip}")
            fi
        fi
    done
    
    if [[ ${#secured_nodes[@]} -gt 0 ]]; then
        just log error "Some nodes are already in secured/bootstrapped state:"
        for node in "${secured_nodes[@]}"; do
            just log error "  - ${node}"
        done
        just log error ""
        just log error "Bootstrap is only for fresh installations. For existing clusters:"
        just log error "  - Use 'just talos health' to check cluster status"
        just log error "  - Use 'just talos reset' to wipe nodes if you want to start fresh"
        just log error "  - Use individual talosctl commands with --talosconfig if cluster is operational"
        exit 1
    fi
    
    just log info "All nodes are in maintenance mode and ready for bootstrap"

[doc('Download Talos machine image')]
download-image version schematic=default_schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Generate schematic ID from Talos schematic')]
gen-schematic-id:
    curl -sX POST --data-binary @<(just template-no-op "{{ talos_dir }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Reset all nodes to maintenance mode for fresh bootstrap')]
reset:
    #!/bin/bash
    set -euo pipefail
    
    # Get node IPs and convert to array
    node_ips=($(just talos __get-node-ips))
    total_nodes=${#node_ips[@]}
    
    echo "⚠️  WARNING: This will reset ALL ${total_nodes} nodes to maintenance mode!"
    echo "⚠️  All data on the nodes will be wiped!"
    echo "⚠️  Nodes will be ready for fresh bootstrap after reset."
    echo
    echo "Nodes to be reset:"
    for ip in "${node_ips[@]}"; do
        echo "  - ${ip}"
    done
    echo
    
    if ! gum confirm "Are you sure you want to reset all nodes?" --default="No"; then
        just log info "Reset cancelled by user"
        exit 0
    fi
    
    just log info "Analyzing node states before reset..."
    
    # Pre-analyze nodes to categorize them
    maintenance_nodes=()
    secured_nodes=()
    corrupted_nodes=()
    offline_nodes=()
    
    for ip in "${node_ips[@]}"; do
        echo -n "Analyzing ${ip}... "
        
        # Check if port is open first
        if ! nmap -Pn -n -p 50000 "${ip}" 2>/dev/null | grep -q "50000/tcp open"; then
            echo "offline"
            offline_nodes+=("${ip}")
            continue
        fi
        
        # Test insecure connection
        if talosctl version --insecure -n "${ip}" >/dev/null 2>&1; then
            echo "maintenance mode"
            maintenance_nodes+=("${ip}")
        else
            # Check error type for secured nodes
            error_output=$(talosctl version --insecure -n "${ip}" 2>&1 || true)
            if echo "$error_output" | grep -q "certificate required"; then
                # Test if secured mode works with existing config
                if talosctl version --talosconfig={{ nodes_dir }}/talosconfig -n "${ip}" >/dev/null 2>&1; then
                    echo "secured (valid certs)"
                    secured_nodes+=("${ip}")
                else
                    # Check if it's the specific expired cert issue
                    secured_error=$(talosctl version --talosconfig={{ nodes_dir }}/talosconfig -n "${ip}" 2>&1 || true)
                    if echo "$secured_error" | grep -q "certificate has expired\|1970"; then
                        echo "corrupted certificates"
                        corrupted_nodes+=("${ip}")
                    else
                        echo "secured (unknown issue)"
                        secured_nodes+=("${ip}")
                    fi
                fi
            else
                echo "unknown state"
                secured_nodes+=("${ip}")
            fi
        fi
    done
    
    echo
    just log info "Node analysis complete:"
    [[ ${#maintenance_nodes[@]} -gt 0 ]] && just log info "Maintenance mode: ${maintenance_nodes[*]}"
    [[ ${#secured_nodes[@]} -gt 0 ]] && just log info "Secured mode: ${secured_nodes[*]}"
    [[ ${#corrupted_nodes[@]} -gt 0 ]] && just log warn "Corrupted certificates: ${corrupted_nodes[*]}"
    [[ ${#offline_nodes[@]} -gt 0 ]] && just log warn "Offline: ${offline_nodes[*]}"
    echo
    
    # Handle corrupted nodes separately
    if [[ ${#corrupted_nodes[@]} -gt 0 ]]; then
        just log error "Found nodes with corrupted/expired certificates that cannot be reset via software:"
        for node in "${corrupted_nodes[@]}"; do
            just log error "  - ${node} (requires manual intervention)"
        done
        echo
        just log error "These nodes need to be manually power-cycled or re-imaged:"
        just log error "1. Power cycle the affected nodes completely"
        just log error "2. Re-flash with fresh Talos image if power cycle doesn't work"
        just log error "3. Ensure nodes boot into maintenance mode"
        echo
        
        if ! gum confirm "Continue with resetting other nodes?" --default="No"; then
            just log info "Reset cancelled due to corrupted nodes"
            exit 1
        fi
    fi
    
    just log info "Attempting to reset accessible nodes..."
    
    reset_count=0
    failed_nodes=()
    skipped_nodes=()
    
    for ip in "${node_ips[@]}"; do
        echo -n "Resetting ${ip}... "
        
        # Skip offline and corrupted nodes
        if [[ " ${offline_nodes[*]} " =~ " ${ip} " ]]; then
            echo "⏭ skipped (offline)"
            skipped_nodes+=("${ip}")
            continue
        fi
        
        if [[ " ${corrupted_nodes[*]} " =~ " ${ip} " ]]; then
            echo "⏭ skipped (corrupted)"
            skipped_nodes+=("${ip}")
            continue
        fi
        
        # Try reset with existing talosconfig first (for secured nodes) with timeout
        if talosctl reset --talosconfig={{ nodes_dir }}/talosconfig -n "${ip}" --graceful=true --wait=true >/dev/null 2>&1; then
            echo "✓ reset (secured mode)"
            reset_count=$((reset_count + 1))
        # Fallback to insecure reset (for nodes already in maintenance mode) with timeout
        elif talosctl reset --insecure -n "${ip}" --graceful=true --wait=true >/dev/null 2>&1; then
            echo "✓ reset (insecure mode)"
            reset_count=$((reset_count + 1))
        else
            echo "✗ failed"
            failed_nodes+=("${ip}")
        fi
    done
    
    echo
    resetable_nodes=$((total_nodes - ${#offline_nodes[@]} - ${#corrupted_nodes[@]}))
    
    if [[ ${reset_count} -eq ${resetable_nodes} ]]; then
        just log info "${reset_count}/${resetable_nodes} accessible nodes reset successfully"
        [[ ${#skipped_nodes[@]} -gt 0 ]] && just log warn "Skipped ${#skipped_nodes[@]} nodes: ${skipped_nodes[*]}"
        just log info "Reset nodes are rebooting and will be ready for bootstrap in ~2-3 minutes"
        just log info "Use 'just talos scan-nodes' to check when nodes are back online"
        if [[ ${#corrupted_nodes[@]} -eq 0 && ${#offline_nodes[@]} -eq 0 ]]; then
            just log info "Use 'just talos bootstrap' to set up the cluster"
        else
            just log warn "Address skipped nodes before running bootstrap"
        fi
    else
        just log warn "${reset_count}/${resetable_nodes} accessible nodes reset successfully"
        if [[ ${#failed_nodes[@]} -gt 0 ]]; then
            just log error "Failed to reset nodes: ${failed_nodes[*]}"
        fi
        if [[ ${#skipped_nodes[@]} -gt 0 ]]; then
            just log error "Skipped nodes: ${skipped_nodes[*]}"
        fi
        just log error "Some nodes require manual intervention"
        exit 1
    fi

[doc('Scan for available Talos nodes on the network')]
scan-nodes:
    #!/bin/bash
    set -euo pipefail
    
    # Get node IPs and convert to array
    node_ips=($(just talos __get-node-ips))
    total_nodes=${#node_ips[@]}
    
    just log info "Scanning ${total_nodes} nodes for Talos port 50000"
    
    open_count=0
    failed_nodes=()
    
    for ip in "${node_ips[@]}"; do
        echo -n "Checking ${ip}... "
        if nmap -Pn -n -p 50000 "${ip}" 2>/dev/null | grep -q "50000/tcp open"; then
            echo "✓ open"
            open_count=$((open_count + 1))
        else
            echo "✗ closed/filtered"
            failed_nodes+=("${ip}")
        fi
    done
    
    echo
    if [[ ${open_count} -eq ${total_nodes} ]]; then
        just log info "All ${total_nodes} nodes have port 50000 open"
        exit 0
    else
        just log warn "${open_count}/${total_nodes} nodes have port 50000 open"
        if [[ ${#failed_nodes[@]} -gt 0 ]]; then
            just log warn "Failed nodes: ${failed_nodes[*]}"
        fi
        exit 1
    fi

[doc('Check cluster health and node status')]
health:
    @just log info "Checking cluster health"
    @echo "=== Cluster Health ==="
    talosctl --talosconfig={{ nodes_dir }}/talosconfig --endpoints=$(just talos __get-controller) --k8s-endpoint=$(just talos __get-controller):6443 health --server=false || true
    @echo
    @echo "=== Node Status ==="
    kubectl get nodes -o wide || true

# =============================================================================
# Secrets Management
# =============================================================================

# Store talsecret.yaml in 1Password as a file attachment (fallback to secure note)
[doc('Store talsecret.yaml in 1Password as a file')]
secrets-store vault=op_vault item_name=(op_item_default + "-talsecret"):
    #!/bin/bash
    set -euo pipefail

    # Ensure 1Password auth first (runtime call to top-level recipe)
    just __check-op-auth

    secrets_file="{{ talos_dir }}/talsecret.yaml"

    # Ensure secrets file exists
    if [[ ! -f "$secrets_file" ]]; then
        just log error "Secrets file not found: $secrets_file"
        just log info "Generate it first with: just talos secrets-generate or just talos extract-secrets"
        exit 1
    fi

    # Check if an item with the same name already exists in the vault
    if op item get "{{ item_name }}" --vault "{{ vault }}" >/dev/null 2>&1; then
        just log info "1Password item already exists: {{ item_name }} (vault: {{ vault }})"
        exit 0
    fi

    just log info "Storing $secrets_file in 1Password as item: {{ item_name }}"

    # Create a Document using op document create (proper way for file uploads)
    if op document create "$secrets_file" --title "{{ item_name }}" --vault "{{ vault }}" >/dev/null 2>&1; then
        just log info "talsecret.yaml uploaded to 1Password as Document: {{ item_name }}"
        exit 0
    fi

    # Fallback: create a secure note with the file content as text
    just log warn "Document creation failed; falling back to secure note with file content"
    file_content=$(cat "$secrets_file")
    if op item create --vault "{{ vault }}" --title "{{ item_name }}" --category "Secure Note" "notesPlain[text]=$file_content" >/dev/null 2>&1; then
        just log info "talsecret.yaml stored in 1Password as Secure Note: {{ item_name }}"
        exit 0
    fi

    just log error "Failed to store secrets in 1Password"
    exit 1

# Restore talsecret.yaml from 1Password Document item
[doc('Restore talsecret.yaml from 1Password')]
secrets-restore vault=op_vault item_name=(op_item_default + "-talsecret"):
    #!/bin/bash
    set -euo pipefail

    # Ensure 1Password auth first
    just __check-op-auth

    secrets_file="{{ talos_dir }}/talsecret.yaml"

    # Check if secrets file already exists locally
    if [[ -f "$secrets_file" ]]; then
        just log warn "Secrets file already exists: $secrets_file"
        just log info "Use 'just talos secrets-clean' first if you want to overwrite it"
        exit 0
    fi

    # Check if 1Password item exists
    if ! op item get "{{ item_name }}" --vault "{{ vault }}" >/dev/null 2>&1; then
        just log error "1Password item '{{ item_name }}' not found in {{ vault }} vault"
        just log info "Use 'just talos secrets-store' first to store the secrets"
        exit 1
    fi

    just log info "Restoring talsecret.yaml from 1Password item: {{ item_name }}"

    # Try to get the file from Document item using op document get
    if op document get "{{ item_name }}" --vault "{{ vault }}" --output "$secrets_file" >/dev/null 2>&1; then
        just log info "talsecret.yaml restored from 1Password Document: $secrets_file"
        exit 0
    fi

    # Fallback: get content from Secure Note
    just log warn "Document retrieval failed; trying to restore from Secure Note content"
    if note_content=$(op item get "{{ item_name }}" --vault "{{ vault }}" --format json 2>/dev/null | jq -r '.fields[] | select(.type=="CONCEALED" or .id=="notesPlain") | .value' 2>/dev/null); then
        if [[ -n "$note_content" && "$note_content" != "null" ]]; then
            echo "$note_content" > "$secrets_file"
            just log info "talsecret.yaml restored from 1Password Secure Note: $secrets_file"
            exit 0
        fi
    fi

    just log error "Failed to restore secrets from 1Password"
    just log info "Check that the item '{{ item_name }}' contains valid YAML content"
    exit 1

# =============================================================================
# Cluster Bootstrap
# =============================================================================

# Bootstrap the Talos cluster (complete setup)
[doc('Bootstrap the Talos cluster')]
bootstrap: __check-talconfig-exists __check-secrets-exists __check-nodes-not-bootstrapped gen-config
    @just log info "Starting Talos cluster bootstrap"
    @just talos __wait-for-nodes
    @just talos config-apply
    @just talos __bootstrap-cluster
    @just talos download-kubeconfig
    @just log info "Talos cluster bootstrap completed successfully"

# Apply updated configuration to existing/running cluster
[doc('Apply updated configuration to existing cluster')]
config-update:
    #!/bin/bash
    set -euo pipefail
    
    just log info "Applying updated configuration to existing cluster"
    
    # Check if talosconfig exists
    if [[ ! -f "{{ nodes_dir }}/talosconfig" ]]; then
        just log error "talosconfig not found - cluster may not be bootstrapped yet"
        just log info "For initial bootstrap, use: just talos bootstrap"
        exit 1
    fi
    
    # Get current node IPs from talconfig.yaml
    node_ips=($(just talos __get-node-ips))
    
    # Check which nodes are accessible
    accessible_nodes=()
    failed_nodes=()
    
    for ip in "${node_ips[@]}"; do
        echo -n "Checking accessibility of ${ip}... "
        if talosctl --talosconfig={{ nodes_dir }}/talosconfig -n "${ip}" version >/dev/null 2>&1; then
            echo "✓ accessible"
            accessible_nodes+=("${ip}")
        else
            echo "✗ failed"
            failed_nodes+=("${ip}")
        fi
    done
    
    if [[ ${#accessible_nodes[@]} -eq 0 ]]; then
        just log error "No nodes are accessible with existing certificates"
        just log error "This may indicate a major configuration change"
        just log info "Consider using 'just talos reset' and 'just talos bootstrap' for major changes"
        exit 1
    fi
    
    just log info "Accessible nodes: ${accessible_nodes[*]}"
    [[ ${#failed_nodes[@]} -gt 0 ]] && just log warn "Inaccessible nodes: ${failed_nodes[*]}"
    
    # Generate the apply command using talhelper
    apply_cmd=$(talhelper gencommand apply \
        --config-file {{ talos_dir }}/talconfig.yaml \
        --env-file {{ talos_dir }}/talenv.yaml \
        --out-dir {{ nodes_dir }})
    
    just log info "Generated apply command for existing cluster"
    just log info "Applying configuration to accessible nodes..."
    
    # Execute the command
    bash -c "$apply_cmd"
    
    just log info "Configuration update completed"
    just log warn "Review cluster status with: just talos health"
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        just log warn "Some nodes were inaccessible during update"
        just log warn "You may need to manually address: ${failed_nodes[*]}"
    fi

# Wait for all nodes to come online
[private]
__wait-for-nodes:
    @just log info "Waiting for all nodes to come online"
    @until just talos scan-nodes >/dev/null 2>&1; do \
        just log warn "Not all nodes are online yet, retrying in 10 seconds..."; \
        sleep 10; \
    done
    @just log info "All nodes are now online and reachable"

# Apply configuration to all nodes
[private]
config-apply:
    @just log info "Applying configuration to all nodes"
    talhelper gencommand apply --config-file {{ talos_dir }}/talconfig.yaml --env-file {{ talos_dir }}/talenv.yaml --extra-flags="--insecure" --out-dir {{ nodes_dir }} | bash
    @just log info "Configuration applied to all nodes"

# Bootstrap the first controller node
[private]
__bootstrap-cluster:
    @just log info "Bootstrapping cluster on first controller node (after 30 seconds)"
    @sleep 30;
    @until talhelper gencommand bootstrap --config-file {{ talos_dir }}/talconfig.yaml --env-file {{ talos_dir }}/talenv.yaml --out-dir {{ nodes_dir }} | bash; do \
        just log warn "Bootstrap failed, retrying in 10 seconds..."; \
        sleep 10; \
    done
    @just log info "Cluster bootstrap completed"

# Download the admin kubeconfig
[private]
download-kubeconfig:
    @just log info "Downloading admin kubeconfig"
    @until talhelper gencommand kubeconfig --config-file {{ talos_dir }}/talconfig.yaml --env-file {{ talos_dir }}/talenv.yaml --extra-flags="{{ workspace_dir }} --force" --out-dir {{ nodes_dir }} | bash; do \
        just log warn "Kubeconfig download failed, retrying in 10 seconds..."; \
        sleep 10; \
    done
    @just log info "Kubeconfig downloaded successfully to workspace root"

# =============================================================================
# Configuration Generation
# =============================================================================

# Generate fresh Talos secrets if file doesn't exist
[doc('Generate fresh Talos secrets')]
secrets-generate:
    #!/bin/bash
    set -euo pipefail

    secrets_file="{{ talos_dir }}/talsecret.yaml"

    if [[ -f "$secrets_file" ]]; then
        just log info "Secrets file already exists: $secrets_file"
        just log info "Use 'just talos secrets-clean' first if you want to regenerate"
        exit 0
    fi

    just log info "Generating fresh Talos secrets"

    # Generate fresh secrets using talosctl
    talosctl gen secrets -o "$secrets_file"

    just log info "Fresh secrets generated: $secrets_file"
    just log warn "Remember to securely store these secrets in 1Password or your preferred secret manager"

# Generate Talos configuration files
[doc('Generate Talos configuration files')]
gen-config: __check-talconfig-exists __clean-nodes __check-secrets-exists
    @just log info "Generating Talos configuration"
    talhelper genconfig -c {{ talos_dir }}/talconfig.yaml --env-file {{ talos_dir }}/talenv.yaml --secret-file {{ talos_dir }}/talsecret.yaml --out-dir {{ nodes_dir }}
    @just log info "Configuration generated in {{ nodes_dir }}"

# =============================================================================
# Cleanup Operations
# =============================================================================

# Clean all generated files (nodes, templates, and secrets)
[doc('Clean all generated files')]
clean: __clean-nodes __clean-templates __secrets-clean
    @just log info "All cleanup completed"

# Clean secrets file only
[doc('Clean secrets file only')]
secrets-clean: __secrets-clean
    @just log info "Secrets file cleaned"

# Clean generated node configuration files
[private]
[doc('Clean generated node configuration files')]
__clean-nodes:
    @just log info "Cleaning generated node configuration files"
    rm -f {{ nodes_dir }}/*.yaml {{ nodes_dir }}/talosconfig
    @just log debug "Node configuration files cleaned"

# Clean generated template files
[private]
[doc('Clean generated template files')]
__clean-templates:
    @just log info "Cleaning generated template files"
    rm -f {{ nodes_dir }}/*.yaml.j2
    @just log debug "Template files cleaned"

# Clean secrets file
[private]
__secrets-clean:
    @just log info "Cleaning secrets file"
    @rm -f {{ talos_dir }}/talsecret.yaml
    @just log debug "Secrets file cleaned"
