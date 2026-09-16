# 🎵 LoopAudio (iOS Native)

Aplicativo nativo para iOS (Swift / SwiftUI), especialmente otimizado para o **iPhone 11** (chip Apple A13 Bionic) e compatível com iOS 15+.

O objetivo do aplicativo é extrair e reproduzir **apenas a faixa de áudio** de qualquer vídeo da fototeca do iPhone em **loop contínuo e sem intervalos perceptíveis (gapless)**, mantendo a reprodução ativa em segundo plano enquanto você utiliza outros aplicativos (como o **TikTok** captando o áudio através do alto-falante do aparelho).

---

## 🚀 Principais Características

1. **Gapless Loop (Sem silêncio entre repetições)**:
   - Utiliza `AVAudioPlayer` com decodificação de hardware e `numberOfLoops = -1`.
   - O decodificador de vídeo fica 100% desligado durante a reprodução, garantindo **consumo mínimo de bateria e CPU**.

2. **Convivência com o TikTok e Outros Apps (Background Audio)**:
   - Configurado com `AVAudioSession.Category.playback` e opção `.mixWithOthers`.
   - O iOS **não interrompe o áudio** quando outro app (como o TikTok) abre o microfone para gravar vídeos ou lives.
   - O som sai com clareza nos alto-falantes estéreo do iPhone 11 para que o microfone externo capte com fidelidade.

3. **Integração com Tela de Bloqueio & Central de Controle**:
   - `MPRemoteCommandCenter`: Controles de Play, Pause e Toggle na Central de Controle e fones Bluetooth.
   - `MPNowPlayingInfoCenter`: Exibe o nome do arquivo, duração e progresso em tempo real.

4. **100% Privado e Local**:
   - Nenhum arquivo é enviado para a internet.
   - Extração ultrarrápida via `AVAssetExportSession` com codec otimizado AAC/M4A.
   - Persistência local: O último arquivo e o volume configurado são salvos automaticamente para que você não precise selecioná-lo de novo ao reabrir o app.

---

## 📂 Estrutura do Projeto

```
LoopAudio/
├── LoopAudio.xcodeproj/       # Projeto nativo do Xcode configurado
│   └── project.pbxproj
├── Package.swift              # Configuração Swift Package Manager
└── LoopAudio/
    ├── Info.plist             # Contém UIBackgroundModes (audio) e permissão de Fotos
    ├── LoopAudioApp.swift      # Ponto de entrada SwiftUI e inicialização de áudio
    ├── Models/
    │   └── AudioTrackInfo.swift # Modelo de dados e metadados persistentes
    ├── Services/
    │   ├── AudioManager.swift   # Gerenciador AVAudioPlayer, AVAudioSession e Lockscreen
    │   └── VideoPicker.swift    # Seletor PHPickerViewController e extrator m4a
    └── Views/
        └── ContentView.swift    # Interface limpa, minimalista e responsiva
```

---

## 🛠️ Como Compilar e Executar no iPhone 11

### Pré-requisitos:
- Um Mac com o **Xcode 14 ou superior** instalado (ou serviço de CI/CD como Xcode Cloud / Codemagic / GitHub Actions com macOS runner).
- Um iPhone 11 (ou simulador iOS 15+).
- Cabo Lightning para conectar o iPhone ao Mac.

### Passo a Passo:

1. **Abrir o Projeto no Xcode**:
   - Dê um duplo clique no arquivo `LoopAudio/LoopAudio.xcodeproj`.

2. **Configurar Assinatura (Signing & Capabilities)**:
   - Selecione o projeto `LoopAudio` na barra lateral esquerda.
   - Vá na aba **Signing & Capabilities**.
   - Em **Team**, selecione sua conta Apple ID (conta gratuita de desenvolvedor é suficiente).
   - Verifique se a capacidade **Background Modes** está habilitada com a opção **Audio, AirPlay, and Picture in Picture** marcada (já configurada no `Info.plist`).

3. **Conectar o iPhone 11**:
   - Conecte seu iPhone 11 ao Mac via cabo.
   - No topo do Xcode, selecione o seu iPhone como destino de execução.
   - Se for a primeira vez instalando no aparelho, ative o *Modo de Desenvolvedor* no iPhone:
     `Ajustes > Privacidade e Segurança > Modo de Desenvolvedor > Ativar`.

4. **Executar (Build & Run)**:
   - Pressione **Cmd + R** ou clique no botão **Play (Run)** no Xcode.
   - O aplicativo será compilado e instalado no seu iPhone 11.

---

## 📱 Testando com o TikTok

1. Abra o **LoopAudio** no iPhone 11.
2. Toque em **"+ Adicionar Vídeo da Fototeca"** e selecione um vídeo gravado no aparelho.
3. O app extrairá o áudio localmente em menos de 1 segundo e iniciará o loop.
4. Ajuste o volume interno desejado.
5. Saia do app (vá para a tela de início ou bloqueie a tela) — note que o áudio continua tocando ininterruptamente.
6. Abra o aplicativo do **TikTok** e toque no botão de criar vídeo (`+`).
7. Grave o vídeo no TikTok normalmente: o microfone do iPhone captará o som do áudio em loop sendo emitido pelo alto-falante.