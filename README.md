# Mixer 0.15

Mixer de áudio nativo para macOS, na barra de menus. Controla volume, silêncio e saída de áudio por aplicativo.

## Download

A versão compilada para Apple Silicon está em [dist/Mixer-0.15-macos-arm64.zip](dist/Mixer-0.15-macos-arm64.zip). Extraia e mova `Mixer.app` para `/Applications`.

O ZIP usa assinatura ad hoc e não é notarizado. O macOS pode solicitar aprovação para abrir o aplicativo.

## Recursos

- Volume, silêncio e dispositivo de saída por app.
- Identificação de abas com áudio no Safari e navegadores Chromium.
- Uma aba: ícone do navegador e título em uma linha. Várias abas: títulos aninhados abaixo do navegador.
- Títulos com marquee, respeitando Reduzir Movimento.
- Nome e artista da faixa do Música quando disponíveis.
- Cache local persistente da identidade da fonte e dos últimos títulos. Uma consulta vazia mantém a última informação até chegar uma nova; informações em cache são identificadas na interface.
- Inicialização com o sistema, opcional.

Volume e saída são compartilhados pelas abas do mesmo cliente de áudio. O Mixer não oferece play/pause.

## Requisitos e permissões

- macOS 14.2 ou posterior.
- O build disponibilizado é `arm64` (Apple Silicon).
- Para compilar: Xcode ou Command Line Tools com SDK que inclua Core Audio Process Taps.
- O macOS pode solicitar captura de áudio do sistema.
- Acessibilidade permite ler os indicadores de áudio da barra de abas, sem percorrer o conteúdo das páginas.
- Automação do Música é usada apenas para consultar nome e artista. Não é necessária Automação dos navegadores.

## Compilar e instalar

```sh
./build.sh
./install-local.command
```

`build/Mixer.app` é o resultado da compilação. A instalação atualiza `/Applications/Mixer.app` e seu registro de ícone.

O build padrão usa a arquitetura local e assinatura ad hoc. Se você criou uma identidade de desenvolvimento com `./repair-signing.command`, builds locais reutilizam essa identidade. O chaveiro e o material de assinatura ficam exclusivamente em `build/Signing`, ignorado pelo Git.

```sh
MIXER_SIGNING=adhoc ./build.sh
./package-release.sh
```

O empacotamento compila uma cópia limpa, sem chaves, preferências, cache, diagnósticos ou arquivos pessoais. Produz um ZIP e seu checksum SHA-256 em `dist/`.

## Testes

```sh
./test-render.sh
```

A suíte cobre ganho, silêncio, conversão de taxa/canais, buffers PCM, exceções Objective-C, agrupamento de processos, leitura de abas e persistência do cache de metadados.

## Arquitetura e limitações

Core Audio Process Taps capturam clientes de áudio. Ganho e silêncio são aplicados em uma rota temporária; AVAudioEngine converte taxa e canais quando necessário. A taxa global dos dispositivos não é alterada.

Processos auxiliares são associados ao app por identidade e árvore de processos. WebKit sem proprietário confirmado permanece genérico até uma identificação válida. Associações em cache exigem o mesmo processo de áudio e navegador; referências de Acessibilidade não são persistidas.

Metadados locais do MediaRemote complementam a leitura de abas e do Música. MediaRemote é uma API privada e pode mudar ou não fornecer informações. Brave e Edge compartilham o leitor Chromium e precisam de validação específica.

Preferências e metadados ficam em `UserDefaults`, localmente. Os diagnósticos ficam em `~/Library/Logs/Mixer/Mixer-diagnostics.txt`; não incluem títulos de abas/faixas. Esses arquivos não fazem parte do repositório ou do ZIP.
