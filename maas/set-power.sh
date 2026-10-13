#!/usr/bin/env bash
# ============================================================
# Configura o power driver de cada no no MAAS.
#
# POR QUE ISTO E O PRIMEIRO BLOQUEADOR REAL
# O MAAS nao comissiona nem implanta sem conseguir ligar/desligar a
# maquina. Em bare metal isso e IPMI/Redfish; aqui as VMs vivem em um host
# Proxmox, entao usamos o power driver "proxmox". O TCC1 nao menciona
# gerencia de energia em nenhuma secao -- acrescentar ao texto do TCC2.
#
# QUANDO RODAR
# Depois do enlistment (nos em estado New), porque o system_id so existe
# apos o MAAS detectar a maquina. Antes de mandar comissionar.
#
# PRE-REQUISITO no host Proxmox: um token de API com o MENOR privilegio
# possivel, concedido VM A VM.
#
#   pveum role add MaasPower --privs "VM.PowerMgmt,VM.Audit"
#   pveum user add maas@pve --password '...'
#   for id in 9101 9102 9103 9104; do
#     pveum acl modify /vms/$id --users maas@pve --roles MaasPower
#   done
#   pveum user token add maas@pve maas-token --privsep 0
#
# ATENCAO: nao conceder em "/vms" e nao usar o papel pronto PVEVMAdmin.
# PVEVMAdmin inclui VM.Allocate, VM.Config.* e VM.Migrate, e um ACL em
# "/vms" alcancaria TODAS as maquinas do host -- inclusive as que nao
# pertencem ao laboratorio. O MAAS so precisa ligar, desligar e consultar
# o estado das maquinas que ele gerencia.
# ============================================================
set -euo pipefail

PROFILE="${MAAS_PROFILE:-admin}"

PVE_HOST="${PVE_HOST:?defina PVE_HOST=https://ip-do-host-proxmox:8006}"
PVE_USER="${PVE_USER:-maas@pve}"
PVE_TOKEN_NAME="${PVE_TOKEN_NAME:?defina PVE_TOKEN_NAME}"
PVE_TOKEN_SECRET="${PVE_TOKEN_SECRET:?defina PVE_TOKEN_SECRET}"

# hostname_no_maas:vmid_no_host_proxmox
NODE_MAP="${NODE_MAP:-pve01:9101 pve02:9102 pve03:9103 pve04:9104}"

command -v jq >/dev/null || { echo "ERRO: jq nao encontrado." >&2; exit 1; }

# ------------------------------------------------------------
# Os nomes dos campos do driver mudam entre versoes do MAAS. Em vez de
# assumir, imprimimos o schema real desta instalacao -- se o update abaixo
# falhar com "Unknown power parameter", compare com esta saida.
# ------------------------------------------------------------
echo "==> Campos do power driver 'proxmox' nesta instalacao do MAAS:"
maas "${PROFILE}" power-drivers read \
  | jq -r '.[] | select(.name=="proxmox") | .fields[] | "    \(.name)  (\(.label))"' \
  || echo "    (nao foi possivel ler o schema -- driver 'proxmox' existe nesta versao?)"
echo

for pair in ${NODE_MAP}; do
  NODE_NAME="${pair%%:*}"
  VM_ID="${pair##*:}"

  SYSTEM_ID="$(maas "${PROFILE}" machines read \
    | jq -r --arg n "${NODE_NAME}" '.[] | select(.hostname==$n) | .system_id' | head -1)"

  if [[ -z "${SYSTEM_ID}" ]]; then
    echo "!! ${NODE_NAME}: ainda nao existe no MAAS."
    echo "   Ligue a VM ${VM_ID} e espere o enlistment (estado New), depois reexecute."
    continue
  fi

  echo "==> ${NODE_NAME} (system_id=${SYSTEM_ID}, VMID=${VM_ID})"
  # ATENCAO: o campo do VMID chama-se power_vm_NAME, nao power_vm_id.
  # Confirmado no MAAS 3.7.3 lendo "machine power-parameters" de uma maquina
  # configurada pela interface web. O rotulo na UI e "ID do no", o que ajuda
  # a confundir. Um nome de parametro errado e aceito em silencio e a maquina
  # fica com power_state=unknown.
  maas "${PROFILE}" machine update "${SYSTEM_ID}" \
    power_type=proxmox \
    power_parameters_power_address="${PVE_HOST}" \
    power_parameters_power_user="${PVE_USER}" \
    power_parameters_power_token_name="${PVE_TOKEN_NAME}" \
    power_parameters_power_token_secret="${PVE_TOKEN_SECRET}" \
    power_parameters_power_vm_name="${VM_ID}" \
    power_parameters_power_verify_ssl=false >/dev/null

  echo "    conferindo o que foi gravado:"
  maas "${PROFILE}" machine power-parameters "${SYSTEM_ID}" \
    | grep -E 'power_address|power_user|power_token_name|power_vm_name' \
    | sed 's/^/      /'

  echo "    power configurado; testando..."
  maas "${PROFILE}" machine query-power-state "${SYSTEM_ID}" | jq -r '"    estado: \(.state)"'
done

echo
echo "Se 'estado' voltou on/off para todos os nos, o MAAS controla energia"
echo "e o comissionamento pode ser disparado."
