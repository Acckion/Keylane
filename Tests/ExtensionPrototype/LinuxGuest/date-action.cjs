const { dateTypes, dateField, submitDate, isFullDay } = require("./form-api.cjs");
const { Calendar } = require("./icon-values.cjs");

function pickDateComponent(component) {
  const action = component("pickDate");
  return Object.assign((props) => action({ ...props, icon: props?.icon ?? Calendar }), { Type: dateTypes, isFullDay });
}

function describePickDate(node) {
  if (node?.type !== "pickDate" || typeof node.props?.onChange !== "function" ||
      typeof node.props.title !== "string" || Buffer.byteLength(node.props.title) > 512) {
    throw new Error("Invalid Action.PickDate");
  }
  const { dateType, minimum, maximum } = dateField(node.props, null);
  return { kind: "pickDate", pickDate: { title: node.props.title, dateType, minimum, maximum } };
}

async function submitPickDate(node, value) {
  const { pickDate } = describePickDate(node);
  await node.props.onChange(submitDate(value, pickDate));
}

module.exports = { pickDateComponent, describePickDate, submitPickDate };
