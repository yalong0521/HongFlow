export interface CardCommand {
  action: string;
  requestId: string;
}

type CardCommandHandler = (command: CardCommand) => void;

/** Holds card commands until the shared app model is ready, including background cold starts. */
export class CardCommandInbox {
  private static pending: CardCommand | undefined;
  private static handler: CardCommandHandler | undefined;

  static offer(command: CardCommand): void {
    CardCommandInbox.pending = command;
    CardCommandInbox.deliver();
  }

  static attach(handler: CardCommandHandler): void {
    CardCommandInbox.handler = handler;
    CardCommandInbox.deliver();
  }

  static detach(handler: CardCommandHandler): void {
    if (CardCommandInbox.handler === handler) {
      CardCommandInbox.handler = undefined;
    }
  }

  private static deliver(): void {
    const command = CardCommandInbox.pending;
    const handler = CardCommandInbox.handler;
    if (command !== undefined && handler !== undefined) {
      // Consume before dispatch: window recreation must not repeat a card click.
      CardCommandInbox.pending = undefined;
      handler(command);
    }
  }
}
