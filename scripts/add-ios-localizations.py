#!/usr/bin/env python3
"""One-shot: add the iPhone/iPad-only UI strings to every Localizable.strings.

The iOS app compiles the shared macOS sources, so it inherited that catalog
for free once the .lproj shipped in the app bundle (see gen-ios-project.py).
Its own screens — connect flow, server list, mirror, workspace screen — were
never in the catalog, so they rendered English in every locale. This appends
them, plus the two editor categories that were never keyed at all.

Idempotent: keys already present in a file are skipped.
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(REPO, "Sources", "AgentCoding")
LANGS = ["en", "de", "es", "fr", "ja", "pt", "zh-Hans", "zh-Hant"]

# key -> {lang: translation}. English is the key itself unless listed.
T = {
    "Account": {
        "de": "Konto", "es": "Cuenta", "fr": "Compte", "ja": "アカウント",
        "pt": "Conta", "zh-Hans": "账户", "zh-Hant": "帳戶"},
    "Add Server": {
        "de": "Server hinzufügen", "es": "Añadir servidor", "fr": "Ajouter un serveur",
        "ja": "サーバを追加", "pt": "Adicionar servidor",
        "zh-Hans": "添加服务器", "zh-Hant": "加入伺服器"},
    "Add a server by address": {
        "de": "Server über Adresse hinzufügen", "es": "Añadir un servidor por dirección",
        "fr": "Ajouter un serveur par adresse", "ja": "アドレスでサーバを追加",
        "pt": "Adicionar um servidor por endereço",
        "zh-Hans": "通过地址添加服务器", "zh-Hant": "透過位址加入伺服器"},
    "Add a server by address with +, or sign in above to reach your bromure.io servers.": {
        "de": "Fügen Sie mit + einen Server über seine Adresse hinzu oder melden Sie sich oben an, um Ihre bromure.io-Server zu erreichen.",
        "es": "Añade un servidor por dirección con +, o inicia sesión arriba para acceder a tus servidores de bromure.io.",
        "fr": "Ajoutez un serveur par adresse avec +, ou connectez-vous ci-dessus pour accéder à vos serveurs bromure.io.",
        "ja": "＋でアドレスからサーバを追加するか、上でサインインして bromure.io のサーバに接続します。",
        "pt": "Adicione um servidor por endereço com +, ou inicie sessão acima para aceder aos seus servidores bromure.io.",
        "zh-Hans": "使用 + 通过地址添加服务器，或在上方登录以访问你的 bromure.io 服务器。",
        "zh-Hant": "使用 + 透過位址加入伺服器，或在上方登入以存取你的 bromure.io 伺服器。"},
    "Arrange a grid in the desktop app, or long-press a terminal tab and “Send to Grid.”": {
        "de": "Ordnen Sie ein Raster in der Desktop-App an oder tippen und halten Sie einen Terminal-Tab und wählen „An Raster senden“.",
        "es": "Organiza una cuadrícula en la app de escritorio, o mantén pulsada una pestaña de terminal y elige «Enviar a la cuadrícula».",
        "fr": "Organisez une grille dans l’app de bureau, ou appuyez longuement sur un onglet de terminal et choisissez « Envoyer à la grille ».",
        "ja": "デスクトップアプリでグリッドを配置するか、ターミナルタブを長押しして「グリッドに送る」を選択します。",
        "pt": "Organize uma grelha na app de secretária, ou mantenha premido um separador de terminal e escolha «Enviar para a grelha».",
        "zh-Hans": "在桌面应用中排列网格，或长按终端标签页并选择“发送到网格”。",
        "zh-Hant": "在桌面 App 中排列格線，或長按終端機標籤頁並選擇「傳送至格線」。"},
    "Attach image": {
        "de": "Bild anhängen", "es": "Adjuntar imagen", "fr": "Joindre une image",
        "ja": "画像を添付", "pt": "Anexar imagem",
        "zh-Hans": "附加图片", "zh-Hant": "附加圖片"},
    "Authorize this device": {
        "de": "Dieses Gerät autorisieren", "es": "Autorizar este dispositivo",
        "fr": "Autoriser cet appareil", "ja": "このデバイスを認証",
        "pt": "Autorizar este dispositivo",
        "zh-Hans": "授权此设备", "zh-Hant": "授權此裝置"},
    "Back to servers": {
        "de": "Zurück zu den Servern", "es": "Volver a los servidores",
        "fr": "Retour aux serveurs", "ja": "サーバ一覧に戻る",
        "pt": "Voltar aos servidores",
        "zh-Hans": "返回服务器", "zh-Hant": "返回伺服器"},
    # Product name — never translated.
    "Bromure": {l: "Bromure" for l in LANGS},
    "Browser": {
        "de": "Browser", "es": "Navegador", "fr": "Navigateur", "ja": "ブラウザ",
        "pt": "Navegador", "zh-Hans": "浏览器", "zh-Hant": "瀏覽器"},
    "Choose File": {
        "de": "Datei auswählen", "es": "Elegir archivo", "fr": "Choisir un fichier",
        "ja": "ファイルを選択", "pt": "Escolher ficheiro",
        "zh-Hans": "选择文件", "zh-Hant": "選擇檔案"},
    "Connect": {
        "de": "Verbinden", "es": "Conectar", "fr": "Se connecter", "ja": "接続",
        "pt": "Ligar", "zh-Hans": "连接", "zh-Hant": "連線"},
    "Copy Key": {
        "de": "Schlüssel kopieren", "es": "Copiar clave", "fr": "Copier la clé",
        "ja": "キーをコピー", "pt": "Copiar chave",
        "zh-Hans": "复制密钥", "zh-Hant": "拷貝密鑰"},
    "Couldn't load the workspace": {
        "de": "Arbeitsbereich konnte nicht geladen werden",
        "es": "No se pudo cargar el espacio de trabajo",
        "fr": "Impossible de charger l’espace de travail",
        "ja": "ワークスペースを読み込めませんでした",
        "pt": "Não foi possível carregar o espaço de trabalho",
        "zh-Hans": "无法加载工作区", "zh-Hant": "無法載入工作區"},
    "Couldn't save the workspace": {
        "de": "Arbeitsbereich konnte nicht gesichert werden",
        "es": "No se pudo guardar el espacio de trabajo",
        "fr": "Impossible d’enregistrer l’espace de travail",
        "ja": "ワークスペースを保存できませんでした",
        "pt": "Não foi possível guardar o espaço de trabalho",
        "zh-Hans": "无法保存工作区", "zh-Hant": "無法儲存工作區"},
    "Finishing sign-in…": {
        "de": "Anmeldung wird abgeschlossen…", "es": "Finalizando inicio de sesión…",
        "fr": "Finalisation de la connexion…", "ja": "サインインを完了しています…",
        "pt": "A concluir o início de sessão…",
        "zh-Hans": "正在完成登录…", "zh-Hant": "正在完成登入…"},
    "Grid": {
        "de": "Raster", "es": "Cuadrícula", "fr": "Grille", "ja": "グリッド",
        "pt": "Grelha", "zh-Hans": "网格", "zh-Hant": "格線"},
    "Loading your servers…": {
        "de": "Ihre Server werden geladen…", "es": "Cargando tus servidores…",
        "fr": "Chargement de vos serveurs…", "ja": "サーバを読み込んでいます…",
        "pt": "A carregar os seus servidores…",
        "zh-Hans": "正在加载你的服务器…", "zh-Hant": "正在載入你的伺服器…"},
    "Local Models": {
        "de": "Lokale Modelle", "es": "Modelos locales", "fr": "Modèles locaux",
        "ja": "ローカルモデル", "pt": "Modelos locais",
        "zh-Hans": "本地模型", "zh-Hant": "本機模型"},
    "My Servers": {
        "de": "Meine Server", "es": "Mis servidores", "fr": "Mes serveurs",
        "ja": "マイサーバ", "pt": "Os meus servidores",
        "zh-Hans": "我的服务器", "zh-Hant": "我的伺服器"},
    "New terminal": {
        "de": "Neues Terminal", "es": "Nuevo terminal", "fr": "Nouveau terminal",
        "ja": "新規ターミナル", "pt": "Novo terminal",
        "zh-Hans": "新建终端", "zh-Hant": "新增終端機"},
    "No servers yet. Turn on Remote Access on a Bromure Mac, or add one by address with +.": {
        "de": "Noch keine Server. Aktivieren Sie den Fernzugriff auf einem Bromure-Mac oder fügen Sie mit + einen über seine Adresse hinzu.",
        "es": "Aún no hay servidores. Activa el acceso remoto en un Mac con Bromure, o añade uno por dirección con +.",
        "fr": "Aucun serveur pour l’instant. Activez l’accès à distance sur un Mac Bromure, ou ajoutez-en un par adresse avec +.",
        "ja": "サーバがまだありません。Bromure を実行中の Mac でリモートアクセスを有効にするか、＋でアドレスから追加してください。",
        "pt": "Ainda não há servidores. Ative o acesso remoto num Mac com Bromure, ou adicione um por endereço com +.",
        "zh-Hans": "还没有服务器。请在运行 Bromure 的 Mac 上开启远程访问，或使用 + 通过地址添加。",
        "zh-Hant": "還沒有伺服器。請在執行 Bromure 的 Mac 上開啟遠端存取，或使用 + 透過位址加入。"},
    "Open a dev server running inside this workspace. It's reached over your private connection — nothing is exposed publicly.": {
        "de": "Öffnen Sie einen Entwicklungsserver, der in diesem Arbeitsbereich läuft. Er wird über Ihre private Verbindung erreicht – nichts wird öffentlich zugänglich gemacht.",
        "es": "Abre un servidor de desarrollo que se ejecuta dentro de este espacio de trabajo. Se accede a través de tu conexión privada: nada queda expuesto públicamente.",
        "fr": "Ouvrez un serveur de développement exécuté dans cet espace de travail. Il est accessible via votre connexion privée — rien n’est exposé publiquement.",
        "ja": "このワークスペース内で動作している開発サーバを開きます。プライベート接続経由で接続され、外部に公開されることはありません。",
        "pt": "Abra um servidor de desenvolvimento em execução neste espaço de trabalho. É acedido através da sua ligação privada — nada fica exposto publicamente.",
        "zh-Hans": "打开在此工作区内运行的开发服务器。它通过你的私有连接访问——不会公开暴露。",
        "zh-Hant": "開啟在此工作區內執行的開發伺服器。它透過你的私人連線存取——不會公開暴露。"},
    "Paste Image": {
        "de": "Bild einsetzen", "es": "Pegar imagen", "fr": "Coller l’image",
        "ja": "画像をペースト", "pt": "Colar imagem",
        "zh-Hans": "粘贴图片", "zh-Hant": "貼上圖片"},
    "Photo Library": {
        "de": "Fotomediathek", "es": "Fototeca", "fr": "Photothèque",
        "ja": "写真ライブラリ", "pt": "Fototeca",
        "zh-Hans": "照片图库", "zh-Hant": "照片圖庫"},
    "Pick a workspace or a board from the sidebar.": {
        "de": "Wählen Sie einen Arbeitsbereich oder ein Board in der Seitenleiste.",
        "es": "Elige un espacio de trabajo o un tablero en la barra lateral.",
        "fr": "Choisissez un espace de travail ou un tableau dans la barre latérale.",
        "ja": "サイドバーからワークスペースまたはボードを選択してください。",
        "pt": "Escolha um espaço de trabalho ou um quadro na barra lateral.",
        "zh-Hans": "从边栏中选择一个工作区或看板。",
        "zh-Hant": "從側邊欄選擇一個工作區或看板。"},
    "Reconnecting — this view may be out of date": {
        "de": "Verbindung wird wiederhergestellt – diese Ansicht ist möglicherweise veraltet",
        "es": "Reconectando: esta vista puede estar desactualizada",
        "fr": "Reconnexion — cette vue peut être obsolète",
        "ja": "再接続中 — この表示は最新ではない可能性があります",
        "pt": "A reconectar — esta vista pode estar desatualizada",
        "zh-Hans": "正在重新连接——此视图可能不是最新的",
        "zh-Hant": "正在重新連線——此畫面可能不是最新的"},
    "Remove from Grid": {
        "de": "Aus Raster entfernen", "es": "Quitar de la cuadrícula",
        "fr": "Retirer de la grille", "ja": "グリッドから削除",
        "pt": "Remover da grelha",
        "zh-Hans": "从网格中移除", "zh-Hant": "從格線中移除"},
    "Reply": {
        "de": "Antworten", "es": "Responder", "fr": "Répondre", "ja": "返信",
        "pt": "Responder", "zh-Hans": "回复", "zh-Hant": "回覆"},
    "Restart to apply these changes?": {
        "de": "Neu starten, um diese Änderungen anzuwenden?",
        "es": "¿Reiniciar para aplicar estos cambios?",
        "fr": "Redémarrer pour appliquer ces changements ?",
        "ja": "変更を適用するために再起動しますか？",
        "pt": "Reiniciar para aplicar estas alterações?",
        "zh-Hans": "重新启动以应用这些更改？", "zh-Hant": "重新啟動以套用這些變更？"},
    "Send": {
        "de": "Senden", "es": "Enviar", "fr": "Envoyer", "ja": "送信",
        "pt": "Enviar", "zh-Hans": "发送", "zh-Hant": "傳送"},
    "Send to Grid": {
        "de": "An Raster senden", "es": "Enviar a la cuadrícula",
        "fr": "Envoyer à la grille", "ja": "グリッドに送る",
        "pt": "Enviar para a grelha",
        "zh-Hans": "发送到网格", "zh-Hant": "傳送至格線"},
    "Servers": {
        "de": "Server", "es": "Servidores", "fr": "Serveurs", "ja": "サーバ",
        "pt": "Servidores", "zh-Hans": "服务器", "zh-Hant": "伺服器"},
    "Sign In": {
        "de": "Anmelden", "es": "Iniciar sesión", "fr": "Se connecter",
        "ja": "サインイン", "pt": "Iniciar sessão",
        "zh-Hans": "登录", "zh-Hant": "登入"},
    "Sign Out": {
        "de": "Abmelden", "es": "Cerrar sesión", "fr": "Se déconnecter",
        "ja": "サインアウト", "pt": "Terminar sessão",
        "zh-Hans": "退出登录", "zh-Hant": "登出"},
    "Sign in to bromure.io": {
        "de": "Bei bromure.io anmelden", "es": "Inicia sesión en bromure.io",
        "fr": "Se connecter à bromure.io", "ja": "bromure.io にサインイン",
        "pt": "Iniciar sessão em bromure.io",
        "zh-Hans": "登录 bromure.io", "zh-Hant": "登入 bromure.io"},
    "Sign in with your bromure.io account to see and connect to your servers from anywhere — no address or port needed.": {
        "de": "Melden Sie sich mit Ihrem bromure.io-Konto an, um Ihre Server von überall zu sehen und sich mit ihnen zu verbinden – ohne Adresse oder Port.",
        "es": "Inicia sesión con tu cuenta de bromure.io para ver tus servidores y conectarte a ellos desde cualquier lugar, sin necesidad de dirección ni puerto.",
        "fr": "Connectez-vous avec votre compte bromure.io pour voir vos serveurs et vous y connecter depuis n’importe où — sans adresse ni port.",
        "ja": "bromure.io アカウントでサインインすると、アドレスやポートを指定せずにどこからでもサーバを表示して接続できます。",
        "pt": "Inicie sessão com a sua conta bromure.io para ver e ligar-se aos seus servidores a partir de qualquer lugar — sem endereço nem porta.",
        "zh-Hans": "使用你的 bromure.io 账户登录，即可随时随地查看并连接你的服务器——无需地址或端口。",
        "zh-Hant": "使用你的 bromure.io 帳戶登入，即可隨時隨地檢視並連線你的伺服器——無需位址或連接埠。"},
    "Signed in": {
        "de": "Angemeldet", "es": "Sesión iniciada", "fr": "Connecté",
        "ja": "サインイン済み", "pt": "Sessão iniciada",
        "zh-Hans": "已登录", "zh-Hant": "已登入"},
    "Start the workspace to see its containers.": {
        "de": "Starten Sie den Arbeitsbereich, um seine Container zu sehen.",
        "es": "Inicia el espacio de trabajo para ver sus contenedores.",
        "fr": "Démarrez l’espace de travail pour voir ses conteneurs.",
        "ja": "コンテナを表示するにはワークスペースを起動してください。",
        "pt": "Inicie o espaço de trabalho para ver os seus contentores.",
        "zh-Hans": "启动工作区以查看其容器。", "zh-Hant": "啟動工作區以檢視其容器。"},
    "This device authenticates by SSH key. On first connect you'll confirm the server's fingerprint and sign in once with the remote account's password to authorize this device.": {
        "de": "Dieses Gerät authentifiziert sich per SSH-Schlüssel. Beim ersten Verbinden bestätigen Sie den Fingerabdruck des Servers und melden sich einmal mit dem Passwort des entfernten Kontos an, um dieses Gerät zu autorisieren.",
        "es": "Este dispositivo se autentica mediante clave SSH. En la primera conexión confirmarás la huella del servidor e iniciarás sesión una vez con la contraseña de la cuenta remota para autorizar este dispositivo.",
        "fr": "Cet appareil s’authentifie par clé SSH. Lors de la première connexion, vous confirmerez l’empreinte du serveur et vous connecterez une fois avec le mot de passe du compte distant pour autoriser cet appareil.",
        "ja": "このデバイスは SSH キーで認証します。初回接続時にサーバのフィンガープリントを確認し、リモートアカウントのパスワードで一度サインインしてこのデバイスを認証します。",
        "pt": "Este dispositivo autentica-se por chave SSH. Na primeira ligação irá confirmar a impressão digital do servidor e iniciar sessão uma vez com a palavra-passe da conta remota para autorizar este dispositivo.",
        "zh-Hans": "此设备通过 SSH 密钥进行身份验证。首次连接时，你需要确认服务器指纹，并使用远程账户密码登录一次以授权此设备。",
        "zh-Hant": "此裝置透過 SSH 密鑰進行驗證。首次連線時，你需要確認伺服器指紋，並使用遠端帳戶密碼登入一次以授權此裝置。"},
    "This device's SSH key isn't authorized on the server yet. Enter the remote Mac's account username and password once to enroll it; subsequent connects are passwordless.": {
        "de": "Der SSH-Schlüssel dieses Geräts ist auf dem Server noch nicht autorisiert. Geben Sie einmalig Benutzernamen und Passwort des Kontos auf dem entfernten Mac ein, um ihn zu registrieren; danach sind Verbindungen passwortlos.",
        "es": "La clave SSH de este dispositivo aún no está autorizada en el servidor. Introduce una vez el nombre de usuario y la contraseña de la cuenta del Mac remoto para registrarla; las conexiones posteriores no requieren contraseña.",
        "fr": "La clé SSH de cet appareil n’est pas encore autorisée sur le serveur. Saisissez une fois le nom d’utilisateur et le mot de passe du compte du Mac distant pour l’enregistrer ; les connexions suivantes se feront sans mot de passe.",
        "ja": "このデバイスの SSH キーはまだサーバで許可されていません。リモート Mac のアカウント名とパスワードを一度入力して登録すると、以降はパスワードなしで接続できます。",
        "pt": "A chave SSH deste dispositivo ainda não está autorizada no servidor. Introduza uma vez o nome de utilizador e a palavra-passe da conta do Mac remoto para a registar; as ligações seguintes dispensam palavra-passe.",
        "zh-Hans": "此设备的 SSH 密钥尚未在服务器上获得授权。请输入一次远程 Mac 的账户用户名和密码以完成注册；之后的连接无需密码。",
        "zh-Hant": "此裝置的 SSH 密鑰尚未在伺服器上獲得授權。請輸入一次遠端 Mac 的帳戶使用者名稱和密碼以完成註冊；之後的連線無需密碼。"},
    "This run captured no transcript.": {
        "de": "Bei diesem Lauf wurde keine Transkription aufgezeichnet.",
        "es": "Esta ejecución no capturó ninguna transcripción.",
        "fr": "Cette exécution n’a produit aucune transcription.",
        "ja": "この実行ではトランスクリプトが記録されませんでした。",
        "pt": "Esta execução não capturou qualquer transcrição.",
        "zh-Hans": "此次运行未捕获转录记录。", "zh-Hant": "此次執行未擷取轉錄記錄。"},
    "This workspace has no open windows yet.": {
        "de": "Dieser Arbeitsbereich hat noch keine geöffneten Fenster.",
        "es": "Este espacio de trabajo aún no tiene ventanas abiertas.",
        "fr": "Cet espace de travail n’a pas encore de fenêtres ouvertes.",
        "ja": "このワークスペースにはまだ開いているウインドウがありません。",
        "pt": "Este espaço de trabalho ainda não tem janelas abertas.",
        "zh-Hans": "此工作区尚未打开任何窗口。", "zh-Hant": "此工作區尚未開啟任何視窗。"},
    "Try Again": {
        "de": "Erneut versuchen", "es": "Reintentar", "fr": "Réessayer",
        "ja": "再試行", "pt": "Tentar novamente",
        "zh-Hans": "重试", "zh-Hant": "重試"},
    "Workspace Settings…": {
        "de": "Arbeitsbereichseinstellungen…", "es": "Ajustes del espacio de trabajo…",
        "fr": "Réglages de l’espace de travail…", "ja": "ワークスペース設定…",
        "pt": "Definições do espaço de trabalho…",
        "zh-Hans": "工作区设置…", "zh-Hant": "工作區設定…"},
    # Marketing hero on the connect screen; the \n is a deliberate line break.
    "Your coding agents and terminals —\\nlive, wherever you are.": {
        "de": "Ihre Coding-Agenten und Terminals –\\nlive, wo immer Sie sind.",
        "es": "Tus agentes de programación y terminales:\\nen vivo, estés donde estés.",
        "fr": "Vos agents de code et vos terminaux —\\nen direct, où que vous soyez.",
        "ja": "コーディングエージェントとターミナルを\\nどこにいてもライブで。",
        "pt": "Os seus agentes de programação e terminais —\\nao vivo, onde quer que esteja.",
        "zh-Hans": "你的编码智能体与终端——\\n无论身在何处，实时可用。",
        "zh-Hant": "你的程式設計代理與終端機——\\n無論身在何處，即時可用。"},
}

HEADER = "\n/* iPhone / iPad client */\n"


def existing_keys(path):
    keys = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=', line)
            if m:
                keys.add(m.group(1))
    return keys


def main():
    for lang in LANGS:
        path = os.path.join(LOC, f"{lang}.lproj", "Localizable.strings")
        have = existing_keys(path)
        rows = []
        for key in sorted(T):
            if key in have:
                continue
            value = T[key].get(lang, key) if lang != "en" else key
            rows.append(f'"{key}" = "{value}";')
        if not rows:
            print(f"{lang}: nothing to add")
            continue
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(HEADER + "\n".join(rows) + "\n")
        print(f"{lang}: +{len(rows)}")


if __name__ == "__main__":
    main()
