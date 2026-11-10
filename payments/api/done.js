import { messagePage } from "../lib/pages.js";
import { page } from "../lib/server.js";

export default function handler(req, res) {
  page(res, 200, messagePage("All set", "Your subscription changes are saved. AnyWhere picks them up the next time it checks."));
}
