import { v5 as uuid } from "uuid";

const name: string = "Keylane extension fixture";
module.exports = uuid(name, uuid.DNS);
