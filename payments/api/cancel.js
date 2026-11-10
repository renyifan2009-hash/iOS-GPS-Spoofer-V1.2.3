import { messagePage } from "../lib/pages.js";
import { page } from "../lib/server.js";

export default function handler(req, res) {
  page(res, 200, messagePage("No charge made", "You left the checkout before paying. You can pick a plan any time in AnyWhere."));
}
