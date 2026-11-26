import express from "express";
import { OrderService } from "./orders/service";
import { MemoryRepository } from "./orders/repository";
import { trace, receipt } from "./lib";
const legacy = require("./legacy.cjs");

const app = express();

async function create(req: any, res: any) {
  const service = new OrderService(new MemoryRepository());
  const result = await service.place(req.body);
  trace(result);
  receipt(result);
  legacy.notify(result);
  [result].forEach((item) => trace(item));
  res.send(<div>{receipt(result)}</div>);
}

app.post("/orders", create);
app.listen(3000);
