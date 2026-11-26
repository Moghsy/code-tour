export interface Order {
  id: string;
  total: number;
}

export interface Repository {
  save(order: Order): Promise<void>;
}

export class MemoryRepository implements Repository {
  private items = new Map<string, Order>();

  async save(order: Order): Promise<void> {
    this.items.set(order.id, order);
  }
}
