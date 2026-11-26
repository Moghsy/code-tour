function notify(message) {
  switch (message) {
    case "":
      return;
    default:
      console.log(message);
  }
}

module.exports = { notify };
