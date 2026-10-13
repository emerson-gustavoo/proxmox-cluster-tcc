#!/usr/bin/env bash
# ============================================================
# Bootstrap do servidor MAAS -- executado UMA VEZ na VM de controle,
# apos "maas init" e "maas createadmin" (Fase 4 do runbook).
#
# Diferenças em relacao ao Apendice D do TCC1:
#   - set -euo pipefail (o apendice segue em frente apos erro)
#   - idempotente: verifica antes de criar, entao pode reexecutar
#   - NAO usa "ipranges type=reserved" para dar IP fixo aos nos. Range
#     reservado apenas exclui a faixa do pool de DHCP; nao cria reserva
#     MAC -> IP. O IP fixo vem do "Static assign" por interface, feito
#     antes do deploy (ver maas/README-power.md e Fase 6 do runbook).
#   - gateway aponta para a VM de controle, que faz NAT (control-vm/nat.sh)
# ============================================================
set -euo pipefail

PROFILE="${MAAS_PROFILE:-admin}"
MAAS_URL="${MAAS_URL:-http://localhost:5240/MAAS}"

PROV_SUBNET="${PROV_SUBNET:-10.10.10.0/24}"
PROV_GATEWAY="${PROV_GATEWAY:-10.10.10.2}"     # VM de controle (NAT)
DHCP_START="${DHCP_START:-10.10.10.100}"
DHCP_END="${DHCP_END:-10.10.10.200}"
UPSTREAM_DNS="${UPSTREAM_DNS:-8.8.8.8}"

for bin in maas jq; do
  command -v "$bin" >/dev/null || { echo "ERRO: '$bin' nao encontrado." >&2; exit 1; }
done

# ------------------------------------------------------------
echo "==> Autenticando no MAAS"
# ------------------------------------------------------------
# Nao tentar autenticar sozinho. O nome do PERFIL do CLI e o nome do USUARIO
# do MAAS sao coisas distintas -- neste laboratorio o perfil e "admin" e o
# usuario e "root" --, entao "maas apikey --username=${PROFILE}" falharia. O
# login e um passo manual, feito uma vez:
#
#   sudo maas apikey --username=<usuario do MAAS> > /root/.maas-api-key
#   maas login ${PROFILE} ${MAAS_URL} "$(cat /root/.maas-api-key)"
if ! maas list 2>/dev/null | grep -q "^${PROFILE}\b"; then
  echo "ERRO: perfil '${PROFILE}' nao autenticado. Rode 'maas login' antes." >&2
  exit 1
else
  echo "    perfil '${PROFILE}' ja autenticado"
fi

# ------------------------------------------------------------
echo "==> DNS forwarder"
# ------------------------------------------------------------
maas "${PROFILE}" maas set-config name=upstream_dns value="${UPSTREAM_DNS}"

# ------------------------------------------------------------
echo "==> Subnet de provisionamento"
# ------------------------------------------------------------
SUBNET_ID="$(maas "${PROFILE}" subnets read \
  | jq -r --arg c "${PROV_SUBNET}" '.[] | select(.cidr==$c) | .id' | head -1)"

if [[ -z "${SUBNET_ID}" ]]; then
  echo "ERRO: subnet ${PROV_SUBNET} nao existe no MAAS." >&2
  echo "Ela e criada automaticamente quando o rack controller detecta a" >&2
  echo "interface da vmbr90. Confirme que a VM de controle tem a segunda" >&2
  echo "NIC configurada com 10.10.10.2/24 e que o MAAS a enxerga." >&2
  exit 1
fi
echo "    subnet id=${SUBNET_ID}"

# Gateway aponta para a VM de controle: sem isso os nos ficam sem rota
# default e a Fase 7 (Ansible) nao consegue baixar pacote nenhum.
maas "${PROFILE}" subnet update "${SUBNET_ID}" \
  gateway_ip="${PROV_GATEWAY}" \
  dns_servers="${PROV_GATEWAY}" >/dev/null
echo "    gateway=${PROV_GATEWAY} dns=${PROV_GATEWAY}"

# ------------------------------------------------------------
echo "==> Faixa dinamica de DHCP (enlistment/commissioning)"
# ------------------------------------------------------------
HAS_DYNAMIC="$(maas "${PROFILE}" ipranges read \
  | jq -r --arg s "${SUBNET_ID}" \
    '[.[] | select((.subnet.id|tostring)==$s and .type=="dynamic")] | length')"

if [[ "${HAS_DYNAMIC}" == "0" ]]; then
  maas "${PROFILE}" ipranges create \
    type=dynamic \
    start_ip="${DHCP_START}" \
    end_ip="${DHCP_END}" \
    subnet="${SUBNET_ID}" \
    comment="Pool de enlistment/commissioning" >/dev/null
  echo "    criada: ${DHCP_START}-${DHCP_END}"
else
  echo "    faixa dinamica ja existe"
fi

# ------------------------------------------------------------
echo "==> Habilitando DHCP na VLAN"
# ------------------------------------------------------------
VLAN_JSON="$(maas "${PROFILE}" subnet read "${SUBNET_ID}" | jq -r '.vlan')"
FABRIC_ID="$(echo "${VLAN_JSON}" | jq -r '.fabric_id')"
VID="$(echo "${VLAN_JSON}" | jq -r '.vid')"
VLAN_ID="$(echo "${VLAN_JSON}" | jq -r '.id')"
DHCP_ON="$(echo "${VLAN_JSON}" | jq -r '.dhcp_on')"

# ------------------------------------------------------------
# TRAVA DE SEGURANCA -- ler antes de remover.
#
# A VM de controle tem perna na rede da empresa, entao o MAAS TAMBEM
# descobre a subnet de producao e a lista ao lado da nossa. Ligar DHCP na
# VLAN errada coloca um servidor DHCP rogue na rede de producao.
#
# Agrava o risco: no lab as duas VLANs tem vid=0 (untagged). So o
# fabric_id as distingue -- identificar por vid daria empate.
#
# Esta trava recusa a operacao se a VLAN alvo carregar qualquer subnet
# alem da de provisionamento.
# ------------------------------------------------------------
VLAN_SUBNETS="$(maas "${PROFILE}" subnets read \
  | jq -r --arg v "${VLAN_ID}" \
    '[.[] | select((.vlan.id|tostring)==$v) | .cidr] | sort | join(" ")')"

if [[ "${VLAN_SUBNETS}" != "${PROV_SUBNET}" ]]; then
  echo "ABORTADO: nao vou ligar DHCP nesta VLAN." >&2
  echo "  vlan_id=${VLAN_ID} fabric=${FABRIC_ID} vid=${VID}" >&2
  echo "  subnets nela: ${VLAN_SUBNETS}" >&2
  echo "  esperado exatamente: ${PROV_SUBNET}" >&2
  exit 1
fi
echo "    trava OK: vlan_id=${VLAN_ID} carrega apenas ${PROV_SUBNET}"

if [[ "${DHCP_ON}" != "true" ]]; then
  RACK_ID="$(maas "${PROFILE}" rack-controllers read | jq -r '.[0].system_id')"
  maas "${PROFILE}" vlan update "${FABRIC_ID}" "${VID}" \
    dhcp_on=true primary_rack="${RACK_ID}" >/dev/null
  echo "    DHCP habilitado (fabric=${FABRIC_ID} vid=${VID} rack=${RACK_ID})"
else
  echo "    DHCP ja habilitado"
fi

# ------------------------------------------------------------
echo "==> Imagem customizada do Debian"
# ------------------------------------------------------------
# O MAAS NAO sincroniza Debian nativamente -- a Secao 2.6 do TCC1 afirma o
# contrario e precisa ser corrigida. A imagem vem do packer-maas (Fase 5).
#
# O tarball PRECISA estar num caminho que o snap do MAAS enxergue. O snap roda
# em mount namespace confinado: um arquivo em /root existe para voce e NAO
# existe para ele. O sintoma e enganoso -- "[Errno 2] No such file or
# directory" apontando para um caminho que o `ls` lista normalmente.
IMAGE_TARBALL="${IMAGE_TARBALL:-/var/snap/maas/common/debian-custom-cloudimg.tar.gz}"

if maas "${PROFILE}" boot-resources read \
     | jq -e '.[] | select(.name=="custom/debian-12")' >/dev/null; then
  echo "    imagem custom/debian-12 ja importada"
elif [[ -f "${IMAGE_TARBALL}" ]]; then
  # Sem 'base_image': o README do packer-maas/debian nao usa esse parametro.
  maas "${PROFILE}" boot-resources create \
    name='custom/debian-12' \
    title='Debian 12 Custom' \
    architecture='amd64/generic' \
    filetype='tgz' \
    content@="${IMAGE_TARBALL}" >/dev/null
  echo "    imagem importada de ${IMAGE_TARBALL}"
else
  echo "    AVISO: ${IMAGE_TARBALL} nao encontrado."
  echo "    Construa a imagem antes:"
  echo "      cd packer-maas/debian && make debian SERIES=bookworm BOOT=bios"
  echo "    e copie o tarball para /var/snap/maas/common/."
fi

echo
echo "Bootstrap concluido."
echo "Proximo passo: configurar o power driver de cada VM (maas/set-power.sh)."
