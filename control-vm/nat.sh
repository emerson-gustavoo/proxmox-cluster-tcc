#!/usr/bin/env bash
# ============================================================
# NAT na VM de controle -- egresso para a rede de provisionamento.
#
# POR QUE ISTO EXISTE
# A vmbr90 tem "bridge-ports none" (isolada de proposito) e a subnet do
# MAAS nasce sem gateway. Os nos, portanto, nao alcancam a internet -- e a
# Fase 7 do runbook precisa baixar de download.proxmox.com, apt.grafana.com
# e do mirror Debian. Sem isto, as roles common, proxmox e alloy falham.
#
# A VM de controle tem uma perna em cada rede, entao ela roteia. O
# isolamento pretendido e preservado: nao existe bridge L2 entre a vmbr90 e
# a rede da empresa, e o DHCP do MAAS continua sem alcance para fora.
#
# DEPOIS DE RODAR ISTO, ajuste no MAAS:
#   Subnets -> 10.10.10.0/24 -> Gateway IP = 10.10.10.2
# senao os nos continuam sem rota default.
# ============================================================
set -euo pipefail

# A cloud image do Ubuntu desliga o predictable naming: as interfaces
# saem como eth0/eth1, nao ens18/ens19. Confirmado no lab em 16/09/2026.
WAN_IF="${WAN_IF:-eth0}"           # perna na rede da empresa (vmbr0 tag 15)
LAN_IF="${LAN_IF:-eth1}"           # perna na vmbr90 (provisionamento)
PROV_SUBNET="${PROV_SUBNET:-10.10.10.0/24}"

if [[ $EUID -ne 0 ]]; then
  echo "Rode como root." >&2
  exit 1
fi

for ifc in "$WAN_IF" "$LAN_IF"; do
  if ! ip link show "$ifc" &>/dev/null; then
    echo "ERRO: interface '$ifc' nao existe. Ajuste WAN_IF/LAN_IF." >&2
    echo "Interfaces disponiveis:" >&2
    ip -br link show >&2
    exit 1
  fi
done

echo "==> Habilitando IP forwarding"
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-maas-nat.conf

# -C testa antes de -A: as regras nao duplicam em reexecucoes.
add_rule() {
  local table=$1; shift
  if ! iptables -t "$table" -C "$@" 2>/dev/null; then
    iptables -t "$table" -A "$@"
    echo "    + iptables -t $table -A $*"
  else
    echo "    = ja existe: $*"
  fi
}

echo "==> Regras de NAT e forwarding"
add_rule nat POSTROUTING -s "$PROV_SUBNET" -o "$WAN_IF" -j MASQUERADE
add_rule filter FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
add_rule filter FORWARD -i "$WAN_IF" -o "$LAN_IF" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "==> Persistindo as regras"
if ! dpkg -s iptables-persistent &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi
netfilter-persistent save

echo
echo "NAT configurado."
echo "AGORA, no MAAS: Subnets -> $PROV_SUBNET -> Gateway IP = 10.10.10.2"
echo "Teste de dentro de um no ja implantado:"
echo "    curl -sI http://download.proxmox.com/debian/pve/ | head -1"
