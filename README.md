# proxmox-cluster-tcc

Infraestrutura como código do TCC **"Provisionamento Automatizado de Clusters
Proxmox VE em Ambiente Bare Metal: Uma Arquitetura com MAAS, Ansible e
Observabilidade Integrada"**. Sistemas de Informação, UNOESC Chapecó.

MAAS provisiona o sistema operacional pela rede; o Ansible instala o Proxmox VE e
forma o cluster; o Grafana Alloy coleta logs e métricas para Loki e Mimir.

> **Status: validado em laboratório.** Em 13/10/2026 este repositório provisionou
> e manteve um cluster de **quatro nós em quórum**, com os nove requisitos
> funcionais demonstrados. Os números de tempo abaixo são medidos, não estimados.

---

## Resultados da validação

| Etapa | Tempo medido |
|---|---|
| Construção da imagem Debian 12 (`packer-maas`), custo único | 17m40s |
| Provisionamento de um nó pelo MAAS (`Ready` → `Deployed`) | 5m25s |
| `site.yml` na primeira execução, instalando tudo em 3 nós | 21m48s |
| `site.yml` na execução que formou o cluster | 3m50s |
| `site.yml` reexecutado sem divergência (**idempotência**) | 1m23s |
| `site.yml` integrando um quarto nó já implantado | 2m40s |

Idempotência (RNF04), em duas execuções do mesmo código a 24 minutos de
distância:

```
05:57   pve01 changed=1   pve02 changed=1   pve03 changed=1   failed=0
06:21   pve01 changed=0   pve02 changed=0   pve03 changed=0   failed=0
```

A primeira repôs configuração que havia divergido enquanto o laboratório esteve
desligado; a segunda não alterou nada. O par demonstra as duas metades do
contrato: converge quando o estado diverge e não age quando já está convergido.

Elasticidade (RNF05), acrescentando o `pve04` ao inventário:

```
pve01 changed=3   pve02 changed=3   pve03 changed=2   pve04 changed=13   failed=0
```

Nos nós já em operação, as alterações são **duas tasks de confiança SSH**, mais
uma terceira acrescentada à automação no mesmo dia. As duas de confiança são
pré-requisito do `pvecm add`, que executa no nó que ingressa e abre SSH como root
para o primário. Nenhum pacote reinstalado, nenhum serviço reiniciado, nenhuma
configuração de rede ou de cluster alterada.

---

## Estrutura

```
proxmox-cluster-tcc/
├── ansible.cfg
├── inventory.yml                # IPs vêm do "Static assign" do MAAS
├── group_vars/all.yml           # TODAS as variáveis ajustáveis
├── site.yml                     # playbook principal
├── roles/
│   ├── common/                  # hostname, /etc/hosts, DNS, NTP
│   ├── proxmox/                 # repo + GPG, kernel PVE, reboot, proxmox-ve, vmbr0
│   ├── alloy/                   # repo Grafana, agente, config.alloy
│   └── cluster/                 # trust → create → join (serial) → verify
├── maas/
│   ├── bootstrap.sh             # subnet, DHCP, gateway, imagem custom
│   └── set-power.sh             # power driver proxmox por nó
├── control-vm/nat.sh            # egresso da rede isolada
└── observability/               # Loki + Mimir + Grafana (compose + provisionamento)
```

---

## Ordem de execução

```bash
# 1. Na VM de controle, depois de "maas init" e do "maas login"
sudo bash control-vm/nat.sh
sudo bash maas/bootstrap.sh

# 2. Ligue as VMs dos nós e espere o enlistment (estado New), então:
export PVE_HOST=https://<ip-do-host-proxmox>:8006
export PVE_TOKEN_NAME=maas-token
export PVE_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
bash maas/set-power.sh

# 3. Comissione e implante os nós pela interface do MAAS.
#    Antes do deploy: aba Network → Static (Client configured) → .11 / .12 / ...

# 4. Stack de observabilidade, na VM de observabilidade
cd observability && cp .env.example .env && $EDITOR .env
docker compose up -d

# 5. Ansible, na VM de controle
ansible -m ping proxmox_cluster          # não siga adiante sem SUCCESS em todos
ansible-playbook site.yml
```

### Ordem dos plays em `site.yml`

`common` → `proxmox` → **`alloy`** → `cluster`

O Alloy entra **antes** da formação do cluster, conforme a Seção 4.7 do projeto: a
coleta precisa estar ativa durante o `pvecm`, que é a etapa mais frágil do
pipeline. A role `cluster` é dividida em quatro arquivos (`trust`, `create`,
`join`, `verify`) porque o `join` exige um play com `serial: 1`. Dois `pvecm add`
simultâneos contra o mesmo cluster são modo de falha conhecido do Corosync.

### Como acrescentar um nó

Duas linhas no `inventory.yml` e reexecutar o `site.yml`. Não é preciso editar
grupos, variáveis ou qualquer outro arquivo: os plays rodam sobre o grupo inteiro
e a condição `inventory_hostname == cluster_primary` decide o papel de cada nó
dentro das tasks.

---

## Rastreabilidade dos requisitos

| RF | Onde é atendido | Evidência |
|---|---|---|
| RF01 detectar via PXE | MAAS + `maas/bootstrap.sh` (DHCP na VLAN) | nó aparece em estado `New` |
| RF02 comissionar após aprovação | MAAS + `maas/set-power.sh` | transição `New → Commissioning → Ready` |
| RF03 instalar Debian não interativo | imagem custom via `packer-maas` + deploy | estado `Deployed` |
| RF04 IP fixo | *Static (Client configured)* no MAAS, antes do deploy | `ip -br a` no nó bate com o `inventory.yml` |
| RF05 disponibilizar o nó | MAAS | ⚠️ o status correto é **`Deployed`**, não `Ready` |
| RF06 instalar Proxmox VE | `roles/proxmox` | task "Coletar versão do Proxmox VE" (`pveversion`) |
| RF07 formar cluster via `pvecm` | `roles/cluster` | `roles/cluster/tasks/verify.yml` |
| RF08 rede, DNS e NTP | `roles/common` + `roles/proxmox` (vmbr0) | `hostname --ip-address`, `chronyc sources`, `ip -br link show vmbr0` |
| RF09 Alloy entregando ao backend | `roles/alloy` | `/ready` do Loki e do Mimir + séries no Grafana |
| RNF03 quórum | `verify.yml` roda em **todos** os nós | `Quorate: Yes` · `Nodes: 4` |
| RNF04 idempotência | reexecutar `site.yml` | `changed=0` em todos os nós |
| RNF05 novo nó | `trust` em malha + `serial: 1` no join | duas linhas no inventário; `changed` concentrado no nó novo |

---

## Gerência de energia

Sem controle remoto de energia o MAAS **não comissiona e não implanta**: ele
precisa ligar a máquina para comissionar, reiniciá-la após instalar e desligá-la
ao final. Em servidor físico é IPMI ou Redfish; na validação em VMs, é o power
driver `proxmox`, que usa a API do host.

A credencial usada é restrita: papel com `VM.PowerMgmt` e `VM.Audit` apenas, e
ACL concedida **VM a VM** (`/vms/9101`, `/vms/9102`, …), nunca em `/vms`. Assim o
MAAS controla exatamente as máquinas do laboratório e nenhuma outra.

---

## Endereçamento

Duas redes. Só as VMs de controle e de observabilidade têm perna nas duas; os nós
ficam exclusivamente na rede de provisionamento e alcançam a internet por NAT
(`control-vm/nat.sh`).

| Host | Rede da empresa (`vmbr0`) | Rede de provisionamento (`vmbr90`) |
|---|---|---|
| VM de controle (MAAS + Ansible) | 172.27.15.170/24 · gw .1 | 10.10.10.2/24 · sem gateway |
| VM de observabilidade | 172.27.15.171/24 · gw .1 | 10.10.10.3/24 · sem gateway |
| pve01 | não tem | 10.10.10.11 |
| pve02 | não tem | 10.10.10.12 |
| pve03 | não tem | 10.10.10.13 |
| pve04 | não tem | 10.10.10.14 |

Bridges no host Proxmox:

| Bridge | Uplink | Função |
|---|---|---|
| `vmbr0` | NIC física | rede da empresa (já existe) |
| `vmbr90` | nenhum | provisionamento: DHCP/PXE do MAAS, isolada |
| `vmbr91` | nenhum | tráfego de guests dentro do cluster aninhado |

A `vmbr91` existe para que a bridge `vmbr0` **dentro** dos nós não caia na
`vmbr90`: um guest fazendo PXE na rede de provisionamento seria detectado pelo
MAAS e entraria no inventário como máquina nova.

## Requisitos do host de validação

Perfil efetivamente usado, com virtualização aninhada habilitada:

| VM | RAM | vCPU | Disco |
|---|---|---|---|
| controle (MAAS + Ansible) | 6 GB | 4 | 80 GB |
| observabilidade | 4 GB | 2 | 60 GB |
| cada nó | 4 GB | 2 | 32 GB |

As VMs dos nós precisam de **duas NICs**: `net0` na `vmbr90` (gerência e PXE,
controlada pelo MAAS) e `net1` na `vmbr91` (uplink da bridge `vmbr0` interna):

```bash
qm set <vmid> --net1 virtio,bridge=vmbr91
```

⚠️ A ordem de boot precisa ser **rede e depois disco** (`--boot
order='net0;scsi0'`). Só com `net0`, o nó instala e entra em kernel panic no
primeiro boot: o "boot local" do MAAS não tem para onde ir e a máquina volta ao
PXE, carregando o kernel de netboot sem dispositivo raiz.

Com uma NIC só, defina `configure_vmbr0: false` em `group_vars/all.yml`.

---

## Limitações declaradas

- Validação em **VMs**, não em bare metal. O fluxo de PXE, comissionamento e
  deploy é o mesmo, mas a equivalência não é integral e está assumida como
  limitação.
- `host_key_checking = False` no `ansible.cfg`, porque os nós são reprovisionados
  e a host key muda a cada deploy.
- Loki e Mimir em modo monolítico, storage em filesystem, `replication_factor: 1`.
  Não é configuração de produção.
- `maas-test-db` em vez de PostgreSQL dedicado.
- Corosync **sem rede dedicada e sem anel redundante**. Split-brain não é
  mitigado.
- **Sem storage compartilhado:** não há migração ao vivo nem alta disponibilidade.
- A `vmbr0` dos nós é escrita em `/etc/network/interfaces.d/` e não no arquivo
  principal, para não tocar na interface de gerência. O Proxmox espera ser dono de
  `/etc/network/interfaces`; convivem, mas é um desvio consciente.
- Após a instalação do Proxmox VE o nó passa a ter **duas pilhas de rede ativas**:
  netplan/`systemd-networkd` herdado do MAAS e `ifupdown2` do Proxmox. Funciona,
  mas não é um arranjo projetado.
- O pipeline **não define senha de root** nos nós. O acesso é só por chave SSH, o
  que é boa propriedade de segurança, mas a interface web do Proxmox autentica
  por PAM e fica inacessível até que se configure autenticação.
- A versão usada, PVE 8, chegou ao fim de suporte em 31/08/2026. Migrar para
  PVE 9 exige trocar `pve_debian_release` e reconstruir a imagem.

---

## Licença

Trabalho acadêmico. Todos os componentes utilizados são software livre:
MAAS (AGPL-3.0), Ansible (GPL-3.0), Proxmox VE (AGPL-3.0), Debian (DFSG),
Grafana Alloy, Loki e Mimir (AGPL-3.0), Docker (Apache-2.0).
