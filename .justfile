set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod talos "talos"
mod kubernetes "kubernetes"

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
__check-op-auth:
  @if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && ! op whoami &> /dev/null; then \
    just log error "1Password CLI not authenticated. Run 'op signin' or set OP_SERVICE_ACCOUNT_TOKEN"; \
    exit 1; \
  fi

[private]
template file *args: __check-op-auth
  @minijinja-cli --env "{{ file }}" {{ args }} | op inject

[private]
template-no-op file *args:
  @minijinja-cli --env "{{ file }}" {{ args }}
