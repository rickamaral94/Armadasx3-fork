# DECISIONS

Decisões de arquitetura do fork, em formato ADR. Uma entrada por decisão, em
ordem cronológica. Uma decisão só entra aqui quando é tomada; hipóteses ainda
em teste vivem no `PERF-LOG.md`.

---

## ADR-0001 — librashader e libadrenotools viram submódulos pinados

**Data:** 2026-09-11
**Status:** aceito
**Fase:** 0 (bootstrap)

### Contexto

O upstream ARMSX3 trata as duas dependências fora de submódulo como checkouts
manuais. O `README.md` manda cloná-las à mão:

    git clone https://github.com/SnowflakePowered/librashader 3rdparty/librashader
    git clone https://github.com/bylaws/libadrenotools android/armsx3-ui/app/src/main/cpp/libadrenotools

e o `.gitignore` continha as duas linhas correspondentes, de modo que nenhum
commit do repositório dizia qual versão delas foi usada.

A consequência é que **a versão contra a qual se compila depende do dia em que
a pessoa clonou**. Duas medições feitas em semanas diferentes podem divergir por
causa da dependência e não do patch em teste, e nada no repositório permitiria
notar. Isso viola diretamente a regra 1 do fork ("medir antes de mudar", com
baseline e hipótese falsificável) e a exigência da seção 4 de registrar o hash
git de tudo que compõe o binário medido. Não é um risco teórico: `librashader`
teve release `v0.12.0` em 2026-07-05 e segue ativo.

### Decisão

Converter as duas em submódulos git pinados, remover as entradas do
`.gitignore`, e adicionar `tools/fork/check-deps.sh`, que falha se a árvore
divergir dos pins.

Commits pinados:

| Dependência | Commit | Referência | Data |
|---|---|---|---|
| `3rdparty/librashader` | `87e8a97b50516d997defeaa168173dcd185d4022` | tag `librashader-*-v0.12.0` | 2026-07-05 |
| `android/armsx3-ui/app/src/main/cpp/libadrenotools` | `8fae8ce254dfc1344527e05301e43f37dea2df80` | `v1.0-18-g8fae8ce` | 2024-09-10 |

Ambos são o `HEAD` do respectivo `master` na data desta decisão.

`librashader` está no commit exato da release v0.12.0, então o pin é uma versão
publicada e não um ponto arbitrário. `libadrenotools` está 18 commits à frente
da sua única tag (`v1.0`) e não recebe commits desde setembro de 2024; pinar o
`HEAD` em vez de `v1.0` pega essas 18 correções num repositório que está
efetivamente parado, o que torna o pin estável na prática.

As URLs em `.gitmodules` são **relativas** (`../../SnowflakePowered/librashader.git`),
seguindo a convenção que o upstream já usa nos outros ~40 submódulos. Elas
resolvem corretamente a partir do `origin` do fork
(`github.com/rickamaral94/Armadasx3-fork` → `github.com/SnowflakePowered/...`),
então nem o fork nem um futuro rebase sobre o upstream precisam de tratamento
especial.

### Verificação

O pin não foi escolhido no escuro. Antes de fixar, a superfície de API que o
código realmente usa foi extraída e compilada contra os headers do commit
candidato:

- **librashader** — `rpcs3/Emu/RSX/VK/upscalers/librashader_pass.h` usa seis
  entradas de `libra_instance_t` (`instance_loaded`, `preset_create`,
  `preset_free`, `vk_filter_chain_create`, `vk_filter_chain_frame`,
  `vk_filter_chain_free`) e seis tipos. Todos presentes e compilando com
  `-std=c++23 -DLIBRA_RUNTIME_VULKAN`. `LIBRASHADER_CURRENT_ABI == 2` e
  `LIBRASHADER_CURRENT_VERSION == 5` no commit pinado. Isto importa porque
  `librashader_ld.h` compara `instance_abi_version()` com `LIBRASHADER_CURRENT_ABI`
  **em runtime**: se o `librashader.so` que o aparelho carrega for de outra ABI,
  o upscaler é recusado silenciosamente em vez de falhar no build.
- **libadrenotools** — `native-lib.cpp` chama `adrenotools_open_libvulkan` com
  8 argumentos e `adrenotools_set_turbo(bool)`, e usa
  `ADRENOTOOLS_DRIVER_CUSTOM`. Assinaturas conferidas por ponteiro de função
  tipado, compilando com `-std=c++20`.

O `check-deps.sh` foi testado nos quatro estados que ele existe para separar:
árvore correta, commit derivado, submódulo sujo no commit certo, e submódulo
não inicializado. Os três últimos saem com código 1.

### Consequências

- `git clone --recursive` passa a bastar; o passo manual do README sai.
- Quem já tem um clone do upstream precisa rodar
  `tools/fork/check-deps.sh --fix` uma vez.
- Um bump de dependência vira um commit revisável com data e motivo, em vez de
  um efeito colateral de reclonar.
- **Divergência com o upstream:** o `.gitmodules` e o `.gitignore` do fork
  passam a diferir. São duas mudanças pequenas e localizadas, mas vão conflitar
  em todo `sync/*` que toque esses arquivos. A resolução é sempre a mesma
  (manter as entradas do fork) e está registrada aqui para não ser
  redescoberta a cada merge.
- `check-deps.sh` sem `--require-all` confere só os dois pins do fork e informa
  quantos submódulos do upstream faltam, para poder rodar num checkout parcial.
  `tools/fork/build.sh` e o CI usam `--require-all`, porque um build real
  precisa de `llvm`, `glslang`, `zlib` e companhia.

### Alternativas descartadas

- **Arquivo de lock com hashes + script de fetch.** Reimplementaria mal o que o
  git já faz. Submódulo é verificado pelo próprio git em `status`, `diff` e
  `clone`; um lock só é verificado por quem lembra de rodar o script.
- **Vendorizar o código das duas.** Inflaria a árvore e criaria um problema de
  licença desnecessário: `librashader` é MPL-2.0 e o fork é GPL-2.0-only. Como
  submódulo, nada de MPL entra no repositório nem é linkado — `librashader_ld.h`
  é um loader header-only permissivo que faz `dlopen` da biblioteca em runtime
  (ver a nota de licenciamento no topo de `upscalers/librashader_pass.h`).
- **Pinar `libadrenotools` na tag `v1.0`.** Descartaria 18 commits de correção
  num repositório parado, sem ganho de estabilidade.

### Pendências que este ADR não resolve

- `android/armsx3-app/` é um segundo módulo de app que também faz
  `add_subdirectory(libadrenotools)`, mas o `android/build-variants.sh` não o
  compila — só `armsx3-ui`. Ele não foi convertido, e sua linha de `.gitignore`
  foi mantida, restrita a esse caminho. Se for código morto, a remoção é
  trabalho da Fase 8 (higienização), não desta fase.
- As instruções de build do `README.md` continuam desatualizadas em relação ao
  `android/configure.sh` (o README diz `RelWithDebInfo`, NDK r27 e API 31; o
  script real usa `Release`, NDK 29 e API 33). Só o bloco de clone foi corrigido
  aqui, para manter o commit atômico. O resto é F0.5.

---

## ADR-0002 — Identidade própria do app, para instalar lado a lado com o oficial

**Data:** 2026-09-11
**Status:** aceito
**Fase:** 0 (bootstrap)

### Contexto

O gate de saída da Fase 0 é "APK do fork instalado lado a lado com o oficial e
funcionalmente idêntico". Isso não é cosmético: **um A/B entre fork e upstream
só é honesto se os dois estiverem instalados ao mesmo tempo, na mesma unidade,
na mesma sessão térmica.** Medir o upstream hoje, desinstalar, instalar o fork e
medir amanhã introduz temperatura, estado de bateria, versão de driver e cache
de shader como variáveis não controladas — exatamente o que a seção 4 manda
fixar.

O upstream publica com `applicationId = com.armsx3` (flavor `github`) e
`com.armsx3.play`. Um fork que mantivesse esses ids instalaria **por cima** do
app oficial, não ao lado.

### Decisão

| Artefato | Upstream | Fork |
|---|---|---|
| `armsx3-ui`, flavor `github` | `com.armsx3` | `com.armsx3.amaral` |
| `armsx3-ui`, flavor `play` | `com.armsx3.play` | `com.armsx3.amaral.play` |
| `armsx3-app` (legado, não compilado) | `com.armsx3` | `com.armsx3.amaral.legacy` |
| Rótulo do launcher | `ARMSX3` | `ARMSX3 Amaral` |

O **pacote Java `com.armsx3`** (`NativeApp`, `Rpcs3Bridge`, `Rpcs3Settings`,
`AssetUtil`) fica **intocado**. Esses nomes estão codificados nos símbolos JNI do
core como `Java_com_armsx3_*`; renomeá-los desligaria todas as chamadas nativas.
`applicationId` e pacote Java são coisas separadas — o próprio upstream já
depende disso, mantendo `namespace = com.armsx2` enquanto publica como
`com.armsx3`. O `namespace` também não foi tocado, pela razão que o upstream já
registra: renomear 129 arquivos não compra nada.

### Bloqueios de instalação lado a lado: auditados, nenhum encontrado

Instalação paralela quebra quando dois APKs disputam um identificador global.
Os manifestos foram auditados e estão limpos:

- **Autoridade de `ContentProvider`** — a única é
  `${applicationId}.updateprovider`, já interpolada. Se fosse literal, a segunda
  instalação falharia com `INSTALL_FAILED_CONFLICTING_PROVIDER`.
- **Permissões customizadas** — nenhuma declarada, então não há
  `INSTALL_FAILED_DUPLICATE_PERMISSION`.
- **Nomes de processo** — `android:process=":discord"` é relativo, portanto já
  prefixado pelo pacote.
- **Diretórios de dados** — derivados do `applicationId` pelo próprio Android.

### Colisões reais encontradas e corrigidas

O que não estava limpo eram três recursos **compartilhados fora** do sandbox:

1. **`android/src/rpcsx-android.cpp`** lia
   `/sdcard/Android/data/com.armsx3/files/driver_env.txt` com o pacote escrito
   à mão. Esse arquivo é como se ajusta `TU_DEBUG` e outras opções do Mesa num
   aparelho sem root. Com o literal, o fork leria o diretório **do app do
   upstream**: um experimento de driver aplicado ao build errado, ou aos dois de
   uma vez.

   **Isto é um bug do upstream, não só um problema do fork** — o flavor `play`
   (`com.armsx3.play`) já hoje lê o diretório do flavor `github`. Corrigido
   derivando o pacote de `/proc/self/cmdline` e cortando em `:` (um processo
   privado é `<pacote>:<nome>` e montaria um caminho inexistente). Candidato a
   PR no upstream.

2. **`Screenshots.kt`** publicava em `Pictures/ARMSX3`, álbum público
   compartilhado. Como a regra 2 exige comparação de imagem em cena fixa como
   gate de RSX, ter capturas dos dois builds intercaladas na mesma pasta com
   nomes indistinguíveis inutiliza o gate. Agora o álbum vem de `app_name`.

3. **`UpdaterEntry.kt`** consultava
   `api.github.com/repos/ARMSX2/ARMSX3/releases`. O fork ofereceria APKs do
   **upstream** — que, com `applicationId` diferente, não sobrescrevem nada:
   instalam um **terceiro** app e deixam o testador sem saber qual build gerou
   os números. Repontado para as releases do fork.

   `pickApkAsset` não precisou mudar: ele casa por sufixo de nome de arquivo
   (`-a13-armv8.2-sdk33` etc.), não por repositório, então continua correto
   desde que o fork use o mesmo esquema de nomes de
   `android/build-variants.sh`.

### Efeitos colaterais que a mudança de id provocou e que foram corrigidos junto

- **`android/build-play-aab.sh`** tem uma verificação *fail-closed* que casava
  `com.armsx3.play` literal no manifesto compilado. Trocar o id sem tocar nela
  faria toda build do bundle reprovar. Atualizada para
  `com.armsx3.amaral.play`, mantida como literal de propósito: derivá-la do
  mesmo gradle que ela verifica não verificaria nada.
- **404 do updater.** O fork ainda não tem releases, e
  `/releases/latest` num repositório sem releases responde 404, que
  `conn.inputStream` lança como `FileNotFoundException` — indistinguível de
  falha de rede, exibida ao usuário como "check failed". Agora o
  `responseCode` é lido antes do stream e 404 vira "nada a oferecer".
- **Links do projeto.** Com o fork virando um app instalável distinto, o botão
  "GitHub" mandaria relatórios de bug do fork para o tracker do upstream, que
  não consegue reproduzi-los. O botão da gaveta e o card "GitHub repository"
  apontam para o fork; foi **acrescentado** um card "Upstream ARMSX3" acima do
  card do RPCS3, de modo que a cadeia de atribuição fica visível e completa
  (fork → ARMSX3 → RPCS3). Um fork GPL deve crédito visível aos seus upstreams,
  não só o header de licença.
- **Wordmark.** Fork e upstream compartilham o ícone, então na tela só o rótulo
  do launcher os separava. `ArmsLogo` lê `app_name`, e a app rodando passa a
  dizer qual build é — uma sessão de medição que confunde as duas produz
  números para o binário errado.

### Verificação

Sem aparelho e sem SDK Android nesta sessão, o que foi verificado por execução:

- A extração de pacote adicionada ao core foi compilada e testada isoladamente
  em 8 casos: processo principal, `com.armsx3`, `com.armsx3.play`, sufixo
  `:discord`, múltiplos `argv`, ausência de NUL final, cmdline vazio e arquivo
  ausente.
- `bash -n` nos scripts alterados.
- A assinatura de `ProjectCard` foi conferida contra os argumentos nomeados
  usados nos cards novos.
- Um shadow introduzido em `Screenshots.kt` (uma `val album` local sobre a
  função `album`) foi removido em vez de apostar na ordem de resolução do
  Kotlin num arquivo que só compila no build Android.

**Não verificado por build:** nada de Kotlin/Gradle/NDK foi compilado — não há
SDK nesta sessão e o build oficial é o CI (F0.6). O gate desta fase continua
dependendo de instalar os dois APKs no Odin 2.

### Pendências deliberadas

- **`News.kt`** continua lendo as releases do **upstream**. É um mural de notas
  de release, texto puro, sem nenhum afordance de download (o comentário do
  arquivo registra que isso é o que o mantém fora do flavor `github`). Para um
  fork que acompanha o upstream, ver o que o upstream publicou é útil. Se algum
  dia confundir o usuário, o conserto é mostrar as duas origens rotuladas, não
  trocar de repositório.
- **Tags de logcat** continuam `"ARMSX3"` nos dois builds, então filtrar por tag
  durante um A/B mistura os dois. Não foi alterado porque são ~15 arquivos e a
  mitigação já existe e é a prática normal: filtrar por PID
  (`adb logcat --pid=$(adb shell pidof com.armsx3.amaral)`). A automação da
  Fase 1 deve usar PID, nunca tag.
- **`discord_bridge.cpp`** busca um asset em
  `raw.githubusercontent.com/ARMSX2/ARMSX3/master/...`. É conteúdo, não
  identidade, e o bridge do Discord depende de um SDK proprietário que este
  fork não distribui. Fica para quando/se esse caminho for exercitado.

---

## ADR-0003 — Geração de quadros (LSFG) fica fora dos builds do fork por ora

**Data:** 2026-09-15
**Status:** aceito
**Fase:** 0 (bootstrap) / 1 (baseline)

### Contexto

O terceiro build no CI configurou o cmake inteiro com sucesso e então morreu em:

    ninja: error: unknown target 'armsx3_lsfg'

`3rdparty/lsfg/CMakeLists.txt` faz `return()` cedo quando
`3rdparty/lsfg/lsfg-vk-android` não existe. Esse diretório é um **checkout
externo** — não está em `.gitmodules`, não está no `.gitignore`, e o README não
o menciona. Ou seja: **um clone limpo do upstream não compila**, e nada avisa.

O `android/build-variants.sh` já tolerava o `.so` não existir (imprime "frame
generation will be absent from this APK" e segue), mas pedia o alvo ao ninja
incondicionalmente — e nomear alvo inexistente é erro duro, não aviso. As duas
metades do script discordavam entre si.

### Decisão

1. **Corrigir o script** (candidato a upstream): só pedir `armsx3_lsfg` quando
   `ninja -t query` confirmar que o alvo existe. As duas metades passam a
   concordar, e um clone limpo compila.
2. **Não buscar `lsfg-vk-android` por enquanto.** Os builds do fork saem sem
   geração de quadros.

### Por que não buscar

- **Não é candidato a pin como librashader e libadrenotools foram (ADR-0001).**
  Aqueles são dependências que o core usa em caminho normal. Esta é uma feature
  opcional, só do flavor `github`, carregada por `dlopen` e já projetada para
  ausência.
- **Geração de quadros é uma variável a medir, não a assumir.** Ela inventa
  quadros; FPS com ela ligada não é comparável a FPS sem ela, e o `BASELINE.md`
  ainda está vazio. Incluí-la no baseline misturaria duas perguntas.
- Um `.so` a menos no APK é uma variável a menos entre o build do fork e o do
  upstream durante o A/B — desde que registrado, que é o propósito deste ADR.

### Consequência que precisa ficar explícita

**O APK do fork não terá geração de quadros enquanto isso valer.** Se o build
do upstream que você comparar tiver, isso é uma diferença conhecida entre os
dois binários e precisa constar em qualquer linha de `PERF-LOG.md` que compare
os dois. Não é uma regressão silenciosa; é uma escolha registrada aqui.

Reverter é barato: clonar `lsfg-vk-android` no lugar certo faz o cmake definir o
alvo de novo, e o script passa a construí-lo sem mais nenhuma mudança.

---

## ADR-0004 — Os efeitos sonoros do menu entram como silêncio gerado

**Data:** 2026-09-15
**Status:** aceito, reversível a custo zero
**Contexto:** primeira build do APK a chegar na compilação Kotlin

### Problema

`:app:compileGithubReleaseKotlin` falhou com quinze erros iguais:

    MenuSfx.kt:43:26 Unresolved reference 'sfx_nav_a'

Os treze arquivos `res/raw/sfx_*` nunca estiveram neste repositório. A causa é
a linha 31 do `.gitignore` da raiz: um `*.wav` sem qualificação, herdado do
RPCS3 upstream, onde serve para dumps de áudio. Nenhum commit desta história
carregou esses arquivos, e `git log -S` confirma que só os `.kt` que os
referenciam existem.

É a mesma armadilha que o `jniLibs/.gitignore` já documenta para o `*.so` e as
bibliotecas do ANGLE — com uma diferença: lá o efeito era silencioso (APK sem
ANGLE, fallback mudo para o driver do sistema); aqui `MenuSfx.kt` referencia os
treces recursos incondicionalmente, então um clone limpo **não compila**.

### Decisão

1. **Desfazer a regra por padrão**, em `res/raw/.gitignore`, com `!sfx_*.wav` —
   mesma forma da correção do ANGLE.
2. **Commitar treze WAVs de 40 ms de silêncio digital**, gerados, com os nomes
   exatos que o código exige.

### Por que silêncio e não outra coisa

As alternativas eram piores:

- **Adaptar o `MenuSfx.kt` para tolerar recurso ausente** mexe em código de UI
  upstream cujo enum expõe `Int` de recurso para outros arquivos. Blast radius
  maior e atrito de rebase (regra 6) para resolver um problema de asset.
- **Gerar os placeholders no build** esconderia o defeito em vez de registrá-lo.

Não tenho os clipes originais e não vou inventar áudio autoral. Silêncio é o
placeholder honesto: o `SoundPool` toca, toda interação funciona, nada quebra.

### Consequência que precisa ficar explícita

**O APK do fork não tem efeitos sonoros de menu.** Quem comparar com um build
feito na máquina de um dev do ARMSX3, onde os arquivos originais estão na cópia
de trabalho, vai ouvir diferença. Não afeta FPS nem frametime em jogo — é UI de
launcher — mas é uma diferença entre binários e por isso está registrada.

Restaurar é só soltar os clipes reais nos mesmos treze nomes: nenhuma mudança de
código, e o `.gitignore` local agora permite commitá-los.

---

## ADR-0005 — Builds do CI continuam com chave de assinatura efêmera

**Data:** 2026-09-16
**Status:** aceito, com custo conhecido e reversível
**Decisão do operador**

### Contexto

O `android-fork.yml` nunca passa `armsx3.uploadSigning`, então o Gradle usa o
`signingConfig` de debug. O keystore de debug é criado pelo AGP na primeira
utilização, e cada execução do CI é uma máquina limpa — logo **cada build sai
com uma chave diferente**. O Android recusa atualizar um app cuja assinatura
mudou:

    Como o pacote tem um conflito com um pacote já existente, o app não foi instalado.

Apareceu na primeira tentativa de atualizar (build `2599205b` por cima de
`9a0c23e2`), que é exatamente quando deveria aparecer.

### Alternativas apresentadas

1. Keystore num secret do GitHub, CI passa `armsx3.uploadSigning`. Correto, sem
   chave privada no repositório; exige gerar o keystore uma vez.
2. Keystore de debug fixo commitado. Zero trabalho, mas é chave privada em
   repositório público.

### Decisão

**Nenhuma das duas por ora.** Fica como está.

### Consequências, que não são pequenas

- **Toda nova build exige desinstalar e reinstalar.** Não há caminho que
  preserve os dados: o assistente deixa escolher o volume, mas o caminho
  continua sendo `Android/data/<pacote>/files` do volume escolhido, que o
  Android apaga no desinstalar.
- **Perde firmware, jogos instalados por .pkg, save data e configs** a cada
  atualização. O backup interno (Configurações → App) cobre saves, troféus,
  perfis e configurações — **não** cobre firmware nem jogos instalados.
- **Consequência de medição, e é a que mais importa aqui:** reinstalar zera o
  cache de shaders e os caches de PPU/SPU, que vivem no data root. Toda primeira
  sessão depois de uma atualização é **cache frio**. Comparar uma medição
  pós-instalação com uma medição de cache quente mistura as duas colunas da
  matriz do `BASELINE.md`, que a seção 4 manda manter separadas. Qualquer linha
  de `PERF-LOG.md` medida logo após uma instalação precisa dizer "frio".

### Como reverter

Qualquer uma das duas alternativas acima, a qualquer momento. A partir daí as
builds atualizam por cima e o problema some — mas a primeira instalação com a
chave nova ainda exige um desinstalar, porque ela também difere da atual.
