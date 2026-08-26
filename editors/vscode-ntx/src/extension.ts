// Real, minimal `ntx-lsp` client -- Stage 1 of
// ~/.claude/plans/lexical-wishing-penguin.md. The server itself only
// speaks the LSP lifecycle today (initialize/initialized/shutdown/exit);
// anything else responds with a real MethodNotFound error rather than a
// stub, so this extension deliberately registers no feature providers of
// its own yet -- it exists only to prove a real editor can launch and
// handshake with `ntx-lsp` over stdio.
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Trace,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const serverPath = vscode.workspace
    .getConfiguration("ntx")
    .get<string>("serverPath", "ntx-lsp");

  const serverOptions: ServerOptions = {
    run: { command: serverPath, transport: TransportKind.stdio },
    debug: { command: serverPath, transport: TransportKind.stdio },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "ntx" }],
  };

  client = new LanguageClient(
    "ntxLanguageServer",
    "natyv .ntx Language Server",
    serverOptions,
    clientOptions,
  );
  context.subscriptions.push(client);

  void client.start().then(() => client?.setTrace(Trace.Verbose));
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
