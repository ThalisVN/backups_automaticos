#!/bin/bash
#
# backup_organizado.sh
# Organiza arquivos por tipo em pastas, permite revisão manual
# e depois compacta e salva em um HD externo escolhido no início.
#
# Uso: ./backup_organizado.sh
#

set -e

# ============================================================
# SPINNER — indicador de carregamento
# ============================================================

# Mostra um spinner giratório enquanto o processo $1 (PID) está rodando,
# com a mensagem $2 ao lado. Some sozinho quando o processo termina.
spinner() {
    local pid="$1"
    local msg="$2"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    tput civis 2>/dev/null || true   # esconde o cursor, se possível

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s %s" "${chars:$i:1}" "$msg"
        i=$(( (i + 1) % ${#chars} ))
        sleep 0.1
    done

    # limpa a linha do spinner
    printf "\r%*s\r" "$(( ${#msg} + 2 ))" ""
    tput cnorm 2>/dev/null || true   # mostra o cursor de novo
}

# ============================================================
# BARRA DE PROGRESSO — estilo blocos (▰▰▰░░░ NN%)
# ============================================================

# Desenha uma barra de progresso: $1 = item atual, $2 = total,
# $3 = texto extra opcional (ex: nome do arquivo sendo copiado).
barra_progresso() {
    local atual="$1" total="$2" extra="${3:-}"
    local largura=30
    local preenchido vazio percentual i barra

    [ "$total" -le 0 ] && return 0

    preenchido=$(( atual * largura / total ))
    vazio=$(( largura - preenchido ))
    percentual=$(( atual * 100 / total ))

    barra=""
    i=0
    while [ "$i" -lt "$preenchido" ]; do
        barra="${barra}▰"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$vazio" ]; do
        barra="${barra}░"
        i=$((i + 1))
    done

    printf "\r[%s] %3d%% (%d/%d) %-40s" "$barra" "$percentual" "$atual" "$total" "${extra:0:40}"
}

# ============================================================
# CONFIGURAÇÕES — AJUSTE AQUI
# ============================================================

# Pasta(s) de origem (o que você quer fazer backup)

# Realiza um teste de existencia das pastas, agora mapeadas de acordo com a identidade criada pelo sistema (pacote xdg-user-dir), o comando depois do :- fica como fallback caso o primeiro nao funcione
test -f "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" && \
    source "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"

ORIGENS=(
    "${XDG_DOCUMENTS_DIR:-$HOME/Documentos}"
    "${XDG_DOWNLOAD_DIR:-$HOME/Downloads}"
    "${XDG_MUSIC_DIR:-$HOME/Músicas}"
    "${XDG_PICTURES_DIR:-$HOME/Imagens}"
    "${XDG_VIDEOS_DIR:-$HOME/Vídeos}"
)

# HD_DESTINO e PASTA_BACKUPS são definidos pela função escolher_hd

# Pasta temporária de staging (onde os arquivos são organizados antes de zipar)
STAGING="/tmp/backup_staging_$(date +%Y%m%d_%H%M%S)"

DATA=$(date +%Y-%m-%d_%H-%M)
NOME_ZIP="backup_${DATA}.zip"

# ============================================================
# FUNÇÕES
# ============================================================

# Lista os dispositivos montados e deixa o usuário escolher o destino
escolher_hd() {
    local candidatos=()
    local base ponto livre tmpfile pid

    tmpfile=$(mktemp)

    # A busca roda em segundo plano, escrevendo os resultados num arquivo
    # temporário, enquanto o spinner gira em primeiro plano.
    (
        for base in "/media/$USER" "/run/media/$USER" "/mnt"; do
            [ -d "$base" ] || continue
            find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r ponto; do
                # só considera se realmente for um dispositivo montado
                if mountpoint -q "$ponto"; then
                    echo "$ponto"
                fi
            done
        done > "$tmpfile"
    ) &
    pid=$!
    spinner "$pid" "Procurando HDs conectados..."
    wait "$pid"

    while IFS= read -r ponto; do
        candidatos+=("$ponto")
    done < "$tmpfile"
    rm -f "$tmpfile"

    echo ""
    echo "Dispositivos encontrados:"
    echo ""

    local opcoes=()
    for ponto in "${candidatos[@]}"; do
        livre=$(df -h --output=avail "$ponto" | tail -n 1 | tr -d ' ')
        opcoes+=("$ponto  (livre: $livre)")
    done
    opcoes+=("Digitar o caminho manualmente")
    opcoes+=("Cancelar")

    PS3=$'\n>> Escolha o HD de destino (número): '
    select escolha in "${opcoes[@]}"; do
        case "$escolha" in
            "Cancelar")
                echo "Backup cancelado."
                exit 0
                ;;
            "Digitar o caminho manualmente")
                read -r -p "Caminho do HD (ex: /media/$USER/MeuHD): " HD_DESTINO
                break
                ;;
            "")
                echo "Opção inválida, tente de novo."
                ;;
            *)
                # pega só o caminho, antes dos dois espaços e do "(livre:"
                HD_DESTINO="${escolha%%  (livre:*}"
                break
                ;;
        esac
    done

    PASTA_BACKUPS="$HD_DESTINO/Backups"
}

# Classifica um arquivo em uma categoria de acordo com a extensão
classificar() {
    local arquivo="$1"
    local ext="${arquivo##*.}"
    ext="${ext,,}"  # minúsculas

    case "$ext" in
        pdf|doc|docx|odt|txt|rtf) echo "Documentos" ;;
        xls|xlsx|ods|csv) echo "Planilhas" ;;
        ppt|pptx|odp) echo "Apresentacoes" ;;
        jpg|jpeg|png|gif|bmp|svg|webp|tiff|heic) echo "Imagens" ;;
        mp4|mkv|avi|mov|wmv|flv|webm) echo "Videos" ;;
        mp3|wav|flac|ogg|aac|m4a) echo "Audios" ;;
        zip|rar|7z|tar|gz|bz2|xz) echo "Compactados" ;;
        py|js|html|css|c|cpp|java|sh|json|xml|php|ts) echo "Codigo" ;;
        *) echo "Outros" ;;
    esac
}

pausa_para_revisao() {
    echo ""
    echo "============================================================"
    echo " Arquivos organizados em: $STAGING"
    echo "============================================================"
    echo ""
    echo "Estrutura criada:"
    find "$STAGING" -maxdepth 1 -mindepth 1 -type d | sort | while read -r pasta; do
        qtd=$(find "$pasta" -type f | wc -l)
        printf "  %-20s %s arquivo(s)\n" "$(basename "$pasta")" "$qtd"
    done
    echo ""
    echo "Você pode agora ABRIR essa pasta e:"
    echo "  - remover arquivos que não quer no backup"
    echo "  - mover arquivos entre as categorias"
    echo "  - adicionar algo manualmente"
    echo ""

    # Tenta abrir o gerenciador de arquivos automaticamente, se disponível
    if command -v xdg-open >/dev/null 2>&1; then
        read -p "Abrir a pasta no gerenciador de arquivos agora? [s/N] " abrir
        if [[ "$abrir" =~ ^[sS]$ ]]; then
            xdg-open "$STAGING" >/dev/null 2>&1 &
        fi
    fi

    read -p ">> Pressione ENTER quando terminar os ajustes e quiser compactar... "
}

# ============================================================
# EXECUÇÃO
# ============================================================

escolher_hd

echo ""
echo "Verificando HD externo em: $HD_DESTINO"
if [ ! -d "$HD_DESTINO" ]; then
    echo "ERRO: HD não encontrado em '$HD_DESTINO'."
    echo "Conecte o HD e rode o script novamente."
    echo "Dica: use 'lsblk' ou 'df -h' para achar o caminho correto."
    exit 1
fi

mkdir -p "$STAGING"

echo "Copiando e organizando arquivos por tipo..."

# Conta o total de arquivos primeiro, para mostrar "X de Y" durante a cópia
TOTAL=0
for origem in "${ORIGENS[@]}"; do
    [ -d "$origem" ] || continue
    TOTAL=$(( TOTAL + $(find "$origem" -type f | wc -l) ))
done

ATUAL=0
for origem in "${ORIGENS[@]}"; do
    if [ ! -d "$origem" ]; then
        echo "  Aviso: origem '$origem' não existe, pulando."
        continue
    fi

    # process substitution (em vez de pipe) para o contador $ATUAL
    # persistir entre os arquivos e entre as pastas de origem
    while IFS= read -r arquivo; do
        ATUAL=$((ATUAL + 1))
        categoria=$(classificar "$arquivo")
        destino_categoria="$STAGING/$categoria"
        mkdir -p "$destino_categoria"
        cp -n "$arquivo" "$destino_categoria/" 2>/dev/null || true

        nome_curto=$(basename "$arquivo")
        barra_progresso "$ATUAL" "$TOTAL" "$nome_curto"
    done < <(find "$origem" -type f)
done
printf "\n"

# Pausa para o usuário revisar/ajustar manualmente
pausa_para_revisao

echo "Compactando e gravando no HD..."
mkdir -p "$PASTA_BACKUPS"

(cd "$STAGING" && zip -r -q "$PASTA_BACKUPS/$NOME_ZIP" .) &
pid=$!
spinner "$pid" "Compactando e gravando no HD..."

if wait "$pid"; then
    echo "Backup salvo com sucesso em: $PASTA_BACKUPS/$NOME_ZIP"
else
    echo "ERRO ao compactar o backup." >&2
    exit 1
fi

# Limpa a pasta temporária de staging
rm -rf "$STAGING"

echo ""
echo "Backups existentes em $PASTA_BACKUPS:"
ls -lh "$PASTA_BACKUPS"/backup_*.zip 2>/dev/null

echo ""
echo "Concluído em $(date)."
