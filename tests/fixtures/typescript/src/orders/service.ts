import type { Order, Repository } from "./repository.js";
import { audit as record } from "@lib/audit";
import * as format from "@lib/format";
import axios from "axios";

export class OrderService {
  constructor(private readonly repository: Repository) {}

  async place(order: Order): Promise<string> {
    if (order.total <= 0) {
      throw new Error("empty order");
    }
    this.validate(order);
    await this.repository.save(order);
    record(order.id);
    await axios.post("/orders", order);
    return format.receipt(order.id);
  }

  private validate = (order: Order) => {
    for (const key of Object.keys(order)) {
      record(key);
    }
  };
}
