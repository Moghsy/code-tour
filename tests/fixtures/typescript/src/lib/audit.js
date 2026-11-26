class Log {
  constructor() {
    this.lines = [];
  }

  write(line) {
    this.lines.push(line);
  }
}

const log = new Log();

export function audit(id) {
  const local = new Log();
  local.write(id);
}
