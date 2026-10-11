"use strict";
var NodusDatabaseQuery = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // shared/companionDatabaseContainer.ts
  var companionDatabaseContainer_exports = {};
  __export(companionDatabaseContainer_exports, {
    prepareCompanionDatabaseDerived: () => prepareCompanionDatabaseDerived,
    queryCompanionDatabaseContainer: () => queryCompanionDatabaseContainer
  });

  // shared/databaseSources.ts
  function translateDatabaseContainerFilter(node, source, primaryInverse) {
    if (!node) return { kind: "true" };
    if (node.type === "condition") {
      const canonical = source.propertyMap[node.columnId] ? node.columnId : primaryInverse.get(node.columnId) ?? node.columnId;
      const columnId = source.propertyMap[canonical];
      return columnId ? { kind: "node", node: { ...node, columnId } } : { kind: "false" };
    }
    const children = node.children.map((child) => translateDatabaseContainerFilter(child, source, primaryInverse));
    if (node.operator === "and") {
      if (children.some((child) => child.kind === "false")) return { kind: "false" };
      const nodes2 = children.flatMap((child) => child.kind === "node" ? [child.node] : []);
      return nodes2.length ? { kind: "node", node: { type: "group", operator: "and", children: nodes2 } } : { kind: "true" };
    }
    if (children.some((child) => child.kind === "true")) return { kind: "true" };
    const nodes = children.flatMap((child) => child.kind === "node" ? [child.node] : []);
    return nodes.length ? { kind: "node", node: { type: "group", operator: "or", children: nodes } } : { kind: "false" };
  }
  function combinedDatabaseContainerFilter(view, local, source, primaryInverse) {
    const translations = [translateDatabaseContainerFilter(view, source, primaryInverse), translateDatabaseContainerFilter(local, source, primaryInverse)];
    if (translations.some((entry) => entry.kind === "false")) return { kind: "false" };
    const nodes = translations.flatMap((entry) => entry.kind === "node" ? [entry.node] : []);
    return !nodes.length ? { kind: "true" } : nodes.length === 1 ? { kind: "node", node: nodes[0] } : { kind: "node", node: { type: "group", operator: "and", children: nodes } };
  }

  // shared/databaseProperties.ts
  function parseObject(raw) {
    if (!raw) return null;
    try {
      const value = JSON.parse(raw);
      return value && typeof value === "object" && !Array.isArray(value) ? value : null;
    } catch {
      return null;
    }
  }
  function encodeDatabaseDate(value) {
    if (!value?.start?.trim()) return null;
    return JSON.stringify({
      start: value.start.trim(),
      end: value.end?.trim() || null,
      includeTime: Boolean(value.includeTime),
      timeZone: value.timeZone?.trim() || null,
      reminderMinutes: Number.isFinite(value.reminderMinutes) ? Math.max(0, Number(value.reminderMinutes)) : null,
      recurrence: value.recurrence ?? null
    });
  }
  function decodeDatabaseDate(raw) {
    if (!raw) return null;
    const object = parseObject(raw);
    if (!object) return { start: raw, end: null, includeTime: raw.includes("T"), timeZone: null, reminderMinutes: null, recurrence: null };
    if (typeof object.start !== "string" || !object.start.trim()) return null;
    const recurrence = ["daily", "weekly", "monthly", "yearly"].includes(String(object.recurrence)) ? object.recurrence : null;
    return {
      start: object.start,
      end: typeof object.end === "string" ? object.end : null,
      includeTime: Boolean(object.includeTime),
      timeZone: typeof object.timeZone === "string" ? object.timeZone : null,
      reminderMinutes: typeof object.reminderMinutes === "number" && Number.isFinite(object.reminderMinutes) ? Math.max(0, object.reminderMinutes) : null,
      recurrence
    };
  }
  function databaseDateSortValue(raw) {
    return decodeDatabaseDate(raw)?.start ?? "";
  }
  function decodeDatabasePeople(raw) {
    if (!raw) return [];
    try {
      const value = JSON.parse(raw);
      if (!Array.isArray(value)) throw new Error("not-array");
      return value.flatMap((item) => {
        if (!item || typeof item !== "object") return [];
        const person = item;
        if (typeof person.label !== "string" || !person.label.trim()) return [];
        const kind = person.kind === "group" ? "group" : "person";
        return [{ id: typeof person.id === "string" && person.id ? person.id : `${kind}:${person.label.toLocaleLowerCase()}`, label: person.label, kind }];
      });
    } catch {
      return [{ id: `person:${raw.toLocaleLowerCase()}`, label: raw, kind: "person" }];
    }
  }
  function decodeDatabaseLocation(raw) {
    if (!raw) return null;
    const object = parseObject(raw);
    if (!object) return { name: raw, address: null, latitude: null, longitude: null };
    if (typeof object.name !== "string" || !object.name.trim()) return null;
    return {
      name: object.name,
      address: typeof object.address === "string" ? object.address : null,
      latitude: typeof object.latitude === "number" ? object.latitude : null,
      longitude: typeof object.longitude === "number" ? object.longitude : null
    };
  }
  function decodeDatabaseButton(raw) {
    const object = parseObject(raw);
    return {
      clicks: typeof object?.clicks === "number" && Number.isSafeInteger(object.clicks) ? Math.max(0, object.clicks) : 0,
      lastClickedAt: typeof object?.lastClickedAt === "string" ? object.lastClickedAt : null,
      lastClickedBy: typeof object?.lastClickedBy === "string" ? object.lastClickedBy : null
    };
  }
  function databasePropertyPlainText(type, raw) {
    if (!raw) return "";
    if (type === "person" || type === "created_by" || type === "last_edited_by") {
      return decodeDatabasePeople(raw).map((person) => person.label).join(", ");
    }
    if (type === "location") {
      const location = decodeDatabaseLocation(raw);
      return location ? [location.name, location.address].filter(Boolean).join(" \xB7 ") : "";
    }
    if (type === "date") {
      const date = decodeDatabaseDate(raw);
      return date ? [date.start, date.end].filter(Boolean).join(" \u2013 ") : "";
    }
    if (type === "button") return String(decodeDatabaseButton(raw).clicks);
    return raw;
  }

  // shared/databases.ts
  var COLUMN_TYPES = [
    { id: "title", label: "T\xEDtulo", icon: "heading", hasOptions: false, available: true },
    { id: "rich_text", label: "Texto enriquecido", icon: "notebook", hasOptions: false, available: true },
    { id: "text", label: "Texto (heredado)", icon: "notebook", hasOptions: false, available: true },
    { id: "number", label: "N\xFAmero", icon: "hash", hasOptions: false, available: true },
    { id: "date", label: "Fecha", icon: "calendar", hasOptions: false, available: true },
    { id: "time", label: "Hora", icon: "clock", hasOptions: false, available: true },
    { id: "select", label: "Selecci\xF3n", icon: "tag", hasOptions: true, available: true },
    { id: "status", label: "Estado", icon: "status", hasOptions: true, available: true },
    { id: "multi_select", label: "Selecci\xF3n m\xFAltiple", icon: "tags", hasOptions: true, available: true },
    { id: "checkbox", label: "Casilla", icon: "check", hasOptions: false, available: true },
    { id: "person", label: "Persona o grupo", icon: "users", hasOptions: false, available: true },
    { id: "url", label: "URL", icon: "link", hasOptions: false, available: true },
    { id: "email", label: "Email", icon: "mail", hasOptions: false, available: true },
    { id: "phone", label: "Tel\xE9fono", icon: "phone", hasOptions: false, available: true },
    { id: "location", label: "Ubicaci\xF3n", icon: "mapPin", hasOptions: false, available: true },
    { id: "files", label: "Archivos", icon: "upload", hasOptions: false, available: true },
    { id: "created_by", label: "Creado por", icon: "user", hasOptions: false, available: true },
    { id: "last_edited_by", label: "Editado por", icon: "user", hasOptions: false, available: true },
    { id: "created_time", label: "Fecha de creaci\xF3n", icon: "calendar", hasOptions: false, available: true },
    { id: "last_edited_time", label: "\xDAltima edici\xF3n", icon: "calendar", hasOptions: false, available: true },
    { id: "unique_id", label: "ID \xFAnico", icon: "hash", hasOptions: false, available: true },
    { id: "button", label: "Bot\xF3n", icon: "play", hasOptions: false, available: true },
    { id: "attachment", label: "Adjunto", icon: "upload", hasOptions: false, available: true },
    { id: "ai", label: "IA", icon: "wand", hasOptions: false, available: true },
    { id: "ai_image", label: "Imagen IA", icon: "image", hasOptions: false, available: true },
    { id: "relation", label: "Relaci\xF3n", icon: "link", hasOptions: false, available: true },
    { id: "rollup", label: "Rollup", icon: "layers", hasOptions: false, available: true },
    { id: "formula", label: "F\xF3rmula", icon: "sigma", hasOptions: false, available: true },
    { id: "comparison", label: "Comparaci\xF3n", icon: "scale", hasOptions: false, available: true }
  ];
  var COLUMN_TYPE_BY_ID = new Map(COLUMN_TYPES.map((d) => [d.id, d]));
  function aggregateRollup(fn, values) {
    const nonEmpty = values.filter((v) => v != null && v.trim() !== "");
    const nums = nonEmpty.map((v) => decodeNumber(v)).filter((n) => n != null);
    const fmt = (n) => Number.isInteger(n) ? String(n) : String(Math.round(n * 100) / 100);
    const percentage = (amount) => values.length ? `${Math.round(amount / values.length * 100)}%` : "";
    const dates = nonEmpty.flatMap((value) => {
      const decoded = decodeDatabaseDate(value);
      if (!decoded?.start) return [];
      const time = Date.parse(decoded.start);
      return Number.isFinite(time) ? [{ raw: decoded.start, time }] : [];
    }).sort((a, b) => a.time - b.time);
    switch (fn) {
      case "count":
        return String(values.length);
      case "count_values":
        return String(nonEmpty.length);
      case "count_empty":
        return String(values.length - nonEmpty.length);
      case "count_unique":
        return String(new Set(nonEmpty).size);
      case "percent_empty":
        return percentage(values.length - nonEmpty.length);
      case "percent_not_empty":
        return percentage(nonEmpty.length);
      case "sum":
        return nums.length ? fmt(nums.reduce((a, b) => a + b, 0)) : "";
      case "average":
        return nums.length ? fmt(nums.reduce((a, b) => a + b, 0) / nums.length) : "";
      case "median": {
        if (!nums.length) return "";
        const sorted = [...nums].sort((a, b) => a - b);
        const middle = Math.floor(sorted.length / 2);
        return fmt(sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2);
      }
      case "min":
        return nums.length ? fmt(Math.min(...nums)) : "";
      case "max":
        return nums.length ? fmt(Math.max(...nums)) : "";
      case "range":
        return nums.length ? fmt(Math.max(...nums) - Math.min(...nums)) : "";
      case "earliest_date":
        return dates[0]?.raw ?? "";
      case "latest_date":
        return dates.at(-1)?.raw ?? "";
      case "date_range":
        return dates.length ? encodeDatabaseDate({ start: dates[0].raw, end: dates.at(-1).raw }) ?? "" : "";
      case "checked":
        return String(values.filter((v) => decodeCheckbox(v)).length);
      case "unchecked":
        return String(values.filter((v) => !decodeCheckbox(v)).length);
      case "percent_checked":
        return percentage(values.filter((v) => decodeCheckbox(v)).length);
      case "percent_unchecked":
        return percentage(values.filter((v) => !decodeCheckbox(v)).length);
      case "show_unique":
        return [...new Set(nonEmpty)].join(", ");
      case "show":
      default:
        return nonEmpty.join(", ");
    }
  }
  function encodeNumber(n) {
    return n == null || !Number.isFinite(n) ? null : String(n);
  }
  function decodeNumber(v) {
    if (v == null) return null;
    const trimmed = v.trim();
    if (trimmed === "") return null;
    const n = Number(trimmed);
    return Number.isFinite(n) ? n : null;
  }
  function decodeCheckbox(v) {
    return v === "1" || v === "true";
  }
  function decodeMultiSelect(v) {
    if (!v) return [];
    try {
      const parsed = JSON.parse(v);
      return Array.isArray(parsed) ? parsed.filter((x) => typeof x === "string") : [];
    } catch {
      return [];
    }
  }

  // shared/databaseFormulaExpression.ts
  var FUNCTIONS = /* @__PURE__ */ new Set([
    "if",
    "coalesce",
    "concat",
    "lower",
    "upper",
    "length",
    "contains",
    "date",
    "dateAdd",
    "dateDiff",
    "year",
    "month",
    "list",
    "count",
    "unique",
    "sum",
    "average",
    "median",
    "min",
    "max",
    "first",
    "last",
    "property",
    "columnTotal",
    "columnMean",
    "rank",
    "percentile",
    "percentOfTotal",
    "diffFromMean",
    "relation",
    "page",
    "personLabel"
  ]);
  var FORMULA_EXPRESSION_FUNCTIONS = [...FUNCTIONS];
  function formulaExpressionDependencies(expression) {
    const out = /* @__PURE__ */ new Set();
    const walk = (node) => {
      if (node.type === "property") out.add(node.columnId);
      else if (node.type === "unary") walk(node.value);
      else if (node.type === "binary") {
        walk(node.left);
        walk(node.right);
      } else if (node.type === "call") {
        if (node.name === "relation") {
          const rel = node.args[0];
          if (rel?.type === "literal" && typeof rel.value === "string") out.add(rel.value);
        }
        node.args.forEach(walk);
      }
    };
    walk(expression);
    return [...out];
  }
  function columnKind(column2) {
    if (!column2) return "text";
    if (column2.type === "number" || column2.type === "rollup" || column2.type === "formula") return "number";
    if (column2.type === "checkbox") return "boolean";
    if (column2.type === "date" || column2.type === "created_time" || column2.type === "last_edited_time") return "date";
    if (column2.type === "multi_select") return "list";
    if (column2.type === "person" || column2.type === "created_by" || column2.type === "last_edited_by") return "person";
    if (column2.type === "relation") return "page";
    return "text";
  }
  function formulaExpressionResultKind(expression, columns = []) {
    const byId = new Map(columns.map((column2) => [column2.id, column2]));
    const infer = (node) => {
      if (node.type === "literal") return typeof node.value === "number" ? "number" : typeof node.value === "boolean" ? "boolean" : "text";
      if (node.type === "property") return columnKind(byId.get(node.columnId));
      if (node.type === "unary") return node.op === "not" ? "boolean" : "number";
      if (node.type === "binary") return ["equal", "not_equal", "gt", "gte", "lt", "lte", "and", "or"].includes(node.op) ? "boolean" : node.op === "add" && (infer(node.left) === "text" || infer(node.right) === "text") ? "text" : "number";
      if (["date", "dateAdd"].includes(node.name)) return "date";
      if (node.name === "relation" || node.name === "list" || node.name === "unique") return "list";
      if ([
        "count",
        "sum",
        "average",
        "median",
        "min",
        "max",
        "dateDiff",
        "year",
        "month",
        "length",
        "columnTotal",
        "columnMean",
        "rank",
        "percentile",
        "percentOfTotal",
        "diffFromMean"
      ].includes(node.name)) return "number";
      if (["contains"].includes(node.name)) return "boolean";
      if (node.name === "page") return "page";
      if (node.name === "if") return node.args[1] ? infer(node.args[1]) : "text";
      return "text";
    };
    return infer(expression);
  }
  function flatten(values) {
    return values.flatMap((value) => Array.isArray(value) ? flatten(value) : [value]);
  }
  function numberOf(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null;
    if (typeof value === "boolean") return value ? 1 : 0;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
    return null;
  }
  function textOf(value) {
    if (value == null) return "";
    if (Array.isArray(value)) return flatten(value).map(textOf).filter(Boolean).join(", ");
    if (typeof value === "object") return value.kind === "page" ? value.title : value.label;
    return String(value);
  }
  function comparable(value) {
    const number2 = numberOf(value);
    return number2 ?? textOf(value);
  }
  function rawProperty(column2, row) {
    if (!column2) return null;
    const raw = row.cells[column2.id] ?? null;
    if (raw == null || raw === "") return null;
    if (column2.type === "number" || column2.type === "formula" || column2.type === "rollup") return numberOf(raw);
    if (column2.type === "checkbox") return raw === "1" || raw === "true";
    if (column2.type === "date" || column2.type === "created_time" || column2.type === "last_edited_time") return decodeDatabaseDate(raw)?.start ?? raw;
    if (column2.type === "person" || column2.type === "created_by" || column2.type === "last_edited_by") {
      return decodeDatabasePeople(raw).map((person) => ({ kind: "person", id: person.id, label: person.label }));
    }
    if (column2.type === "multi_select") {
      try {
        const ids = JSON.parse(raw);
        return Array.isArray(ids) ? ids.map(String) : [raw];
      } catch {
        return [raw];
      }
    }
    return raw;
  }
  function addDate(value, amount, unit) {
    const date = new Date(textOf(value));
    const count = numberOf(amount);
    if (!Number.isFinite(date.getTime()) || count == null) return null;
    if (unit === "day" || unit === "days") date.setUTCDate(date.getUTCDate() + count);
    else if (unit === "week" || unit === "weeks") date.setUTCDate(date.getUTCDate() + count * 7);
    else if (unit === "month" || unit === "months") date.setUTCMonth(date.getUTCMonth() + count);
    else if (unit === "year" || unit === "years") date.setUTCFullYear(date.getUTCFullYear() + count);
    else return null;
    return date.toISOString();
  }
  function evaluateFormulaExpression(expression, context) {
    const evaluate = (node) => {
      if (node.type === "literal") return node.value;
      if (node.type === "property") return rawProperty(context.columns.get(node.columnId), context.row);
      if (node.type === "unary") {
        const value = evaluate(node.value);
        return node.op === "not" ? !value : -(numberOf(value) ?? 0);
      }
      if (node.type === "binary") {
        if (node.op === "and") return Boolean(evaluate(node.left)) && Boolean(evaluate(node.right));
        if (node.op === "or") return Boolean(evaluate(node.left)) || Boolean(evaluate(node.right));
        const left = evaluate(node.left);
        const right = evaluate(node.right);
        if (node.op === "add" && (typeof left === "string" || typeof right === "string")) return textOf(left) + textOf(right);
        if (node.op === "equal") return comparable(left) === comparable(right);
        if (node.op === "not_equal") return comparable(left) !== comparable(right);
        if (node.op === "gt") return comparable(left) > comparable(right);
        if (node.op === "gte") return comparable(left) >= comparable(right);
        if (node.op === "lt") return comparable(left) < comparable(right);
        if (node.op === "lte") return comparable(left) <= comparable(right);
        const a = numberOf(left);
        const b = numberOf(right);
        if (a == null || b == null) return null;
        if (node.op === "add") return a + b;
        if (node.op === "subtract") return a - b;
        if (node.op === "multiply") return a * b;
        if (node.op === "divide") return b === 0 ? null : a / b;
        return b === 0 ? null : a % b;
      }
      if (["columnTotal", "columnMean", "rank", "percentile", "percentOfTotal", "diffFromMean"].includes(node.name)) {
        const property = node.args[0];
        if (property?.type !== "property") return null;
        const stats = context.columnStats?.get(property.columnId);
        const self = numberOf(evaluate(property));
        if (!stats) return null;
        if (node.name === "columnTotal") return stats.total;
        if (node.name === "columnMean") return stats.sorted.length ? stats.mean : null;
        if (self == null || !stats.sorted.length) return null;
        if (node.name === "percentOfTotal") return stats.total === 0 ? null : self / stats.total * 100;
        if (node.name === "diffFromMean") return self - stats.mean;
        if (node.name === "rank") return 1 + stats.sorted.filter((value) => value > self).length;
        return stats.sorted.filter((value) => value < self).length / stats.sorted.length * 100;
      }
      const args = node.args.map(evaluate);
      if (node.name === "if") return args[0] ? args[1] ?? null : args[2] ?? null;
      if (node.name === "coalesce") return args.find((value) => value != null && textOf(value) !== "") ?? null;
      if (node.name === "concat") return args.map(textOf).join("");
      if (node.name === "lower") return textOf(args[0]).toLocaleLowerCase();
      if (node.name === "upper") return textOf(args[0]).toLocaleUpperCase();
      if (node.name === "length") return Array.isArray(args[0]) ? flatten(args[0]).length : textOf(args[0]).length;
      if (node.name === "contains") return textOf(args[0]).toLocaleLowerCase().includes(textOf(args[1]).toLocaleLowerCase());
      if (node.name === "date") {
        const date = new Date(textOf(args[0]));
        return Number.isFinite(date.getTime()) ? date.toISOString() : null;
      }
      if (node.name === "dateAdd") return addDate(args[0], args[1], textOf(args[2]));
      if (node.name === "dateDiff") {
        const a = new Date(textOf(args[0])).getTime();
        const b = new Date(textOf(args[1])).getTime();
        return Number.isFinite(a) && Number.isFinite(b) ? Math.round((a - b) / 864e5) : null;
      }
      if (node.name === "year" || node.name === "month") {
        const date = new Date(textOf(args[0]));
        return Number.isFinite(date.getTime()) ? node.name === "year" ? date.getUTCFullYear() : date.getUTCMonth() + 1 : null;
      }
      if (node.name === "list") return flatten(args);
      if (node.name === "relation") {
        const relationId = textOf(args[0]);
        const targetId = textOf(args[1]);
        return context.relatedValues?.(relationId, targetId) ?? [];
      }
      if (node.name === "page") return { kind: "page", id: textOf(args[0]), title: textOf(args[1] ?? args[0]) };
      if (node.name === "personLabel") {
        const first = flatten([args[0]]).find((value) => !Array.isArray(value) && typeof value === "object" && value != null && value.kind === "person");
        return first ? first.label : textOf(args[0]);
      }
      const values = flatten(args).filter((value) => value != null);
      if (node.name === "count") return values.length;
      if (node.name === "unique") return [...new Map(values.map((value) => [JSON.stringify(value), value])).values()];
      if (node.name === "first") return values[0] ?? null;
      if (node.name === "last") return values.at(-1) ?? null;
      const numbers = values.map(numberOf).filter((value) => value != null).sort((a, b) => a - b);
      if (!numbers.length) return null;
      if (node.name === "sum") return numbers.reduce((total, value) => total + value, 0);
      if (node.name === "average") return numbers.reduce((total, value) => total + value, 0) / numbers.length;
      if (node.name === "median") {
        const middle = Math.floor(numbers.length / 2);
        return numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2;
      }
      if (node.name === "min") return numbers[0];
      if (node.name === "max") return numbers.at(-1) ?? null;
      return null;
    };
    return evaluate(expression);
  }
  function formulaRuntimeToRaw(value) {
    if (value == null) return null;
    if (typeof value === "boolean") return value ? "1" : "0";
    if (typeof value === "number") return Number.isFinite(value) ? String(Math.round(value * 1e10) / 1e10) : null;
    if (Array.isArray(value) || typeof value === "object") return JSON.stringify(value);
    return value;
  }
  function validateFormulaExpression(expression, columns) {
    const known = new Set(columns.map((column2) => column2.id));
    for (const dependency of formulaExpressionDependencies(expression)) {
      if (!known.has(dependency)) return "La f\xF3rmula usa una propiedad que ya no existe.";
    }
    const validate = (node) => {
      if (node.type === "call") {
        if (node.name === "if" && node.args.length !== 3) return "if() necesita condici\xF3n, resultado y alternativa.";
        if (node.name === "relation" && (node.args.length !== 2 || node.args.some((arg) => arg.type !== "literal" || typeof arg.value !== "string"))) return "relation() necesita los ids de relaci\xF3n y propiedad como texto.";
        if (["dateAdd"].includes(node.name) && node.args.length !== 3) return `${node.name}() necesita tres argumentos.`;
        if (["dateDiff", "contains"].includes(node.name) && node.args.length !== 2) return `${node.name}() necesita dos argumentos.`;
        if (["columnTotal", "columnMean", "rank", "percentile", "percentOfTotal", "diffFromMean"].includes(node.name) && (node.args.length !== 1 || node.args[0].type !== "property")) return `${node.name}() necesita una propiedad.`;
        for (const arg of node.args) {
          const problem = validate(arg);
          if (problem) return problem;
        }
      } else if (node.type === "binary") return validate(node.left) ?? validate(node.right);
      else if (node.type === "unary") return validate(node.value);
      return null;
    };
    return validate(expression);
  }
  function formulaExpressionGlobalStatDependencies(expression) {
    const out = /* @__PURE__ */ new Set();
    const walk = (node) => {
      if (node.type === "call") {
        if (["columnTotal", "columnMean", "rank", "percentile", "percentOfTotal", "diffFromMean"].includes(node.name) && node.args[0]?.type === "property") out.add(node.args[0].columnId);
        node.args.forEach(walk);
      } else if (node.type === "binary") {
        walk(node.left);
        walk(node.right);
      } else if (node.type === "unary") walk(node.value);
    };
    walk(expression);
    return [...out];
  }
  function formulaExpressionRelations(expression) {
    const out = /* @__PURE__ */ new Map();
    const walk = (node) => {
      if (node.type === "call") {
        if (node.name === "relation") {
          const relation = node.args[0];
          const target = node.args[1];
          if (relation?.type === "literal" && typeof relation.value === "string" && target?.type === "literal" && typeof target.value === "string") {
            out.set(`${relation.value}\0${target.value}`, { relationColumnId: relation.value, targetColumnId: target.value });
          }
        }
        node.args.forEach(walk);
      } else if (node.type === "binary") {
        walk(node.left);
        walk(node.right);
      } else if (node.type === "unary") walk(node.value);
    };
    walk(expression);
    return [...out.values()];
  }

  // shared/databaseFormula.ts
  function outputKind(o) {
    if (o.kind === "number") return "number";
    if (o.kind === "text") return "text";
    return null;
  }
  function formulaResultKind(spec) {
    if (!spec) return "text";
    switch (spec.kind) {
      case "arithmetic":
      case "columnStat":
        return "number";
      case "concat":
        return "text";
      case "expression":
        return (spec.resultKind ?? formulaExpressionResultKind(spec.ast)) === "number" ? "number" : "text";
      case "ifThen": {
        const kinds = [...spec.rules.map((r) => outputKind(r.output)), outputKind(spec.otherwise)].filter(Boolean);
        return kinds.length > 0 && kinds.every((k) => k === "number") ? "number" : "text";
      }
    }
  }
  function formulaDependencies(spec) {
    if (!spec) return [];
    const out = /* @__PURE__ */ new Set();
    switch (spec.kind) {
      case "arithmetic":
        for (const o of spec.operands) if (o.kind === "column") out.add(o.columnId);
        break;
      case "columnStat":
        if (spec.columnId) out.add(spec.columnId);
        break;
      case "ifThen":
        for (const r of spec.rules) {
          for (const c of r.conditions) if (c.columnId) out.add(c.columnId);
          if (r.output.kind === "column") out.add(r.output.columnId);
        }
        if (spec.otherwise.kind === "column") out.add(spec.otherwise.columnId);
        break;
      case "concat":
        for (const p of spec.parts) if (p.kind === "column") out.add(p.columnId);
        break;
      case "expression":
        formulaExpressionDependencies(spec.ast).forEach((id) => out.add(id));
        break;
    }
    return [...out];
  }
  function validateFormula(spec, columns) {
    if (!spec) return "Esta columna todav\xEDa no tiene f\xF3rmula.";
    const known = new Set(columns.map((c) => c.id));
    for (const id of formulaDependencies(spec)) {
      if (!known.has(id)) return "La f\xF3rmula usa una columna que ya no existe.";
    }
    switch (spec.kind) {
      case "arithmetic":
        if (spec.operands.length < (spec.op === "countFilled" ? 1 : 2)) return "Elige al menos dos columnas o n\xFAmeros.";
        return null;
      case "columnStat":
        if (!spec.columnId) return "Elige la columna que quieres medir.";
        return null;
      case "ifThen":
        if (spec.rules.length === 0) return "A\xF1ade al menos una regla.";
        if (spec.rules.some((r) => r.conditions.length === 0)) return "Cada regla necesita al menos una condici\xF3n.";
        return null;
      case "concat":
        if (spec.parts.length === 0) return "A\xF1ade al menos una columna o un texto.";
        return null;
      case "expression":
        return spec.parseError || validateFormulaExpression(spec.ast, columns);
    }
  }
  function comparableType(column2) {
    if (column2.type === "comparison") return "text";
    if (column2.type === "rich_text" || column2.type === "url" || column2.type === "email" || column2.type === "phone" || column2.type === "location" || column2.type === "person" || column2.type === "created_by" || column2.type === "last_edited_by" || column2.type === "unique_id") return "text";
    if (column2.type === "status") return "select";
    if (column2.type === "files") return "attachment";
    if (column2.type === "created_time" || column2.type === "last_edited_time") return "date";
    if (column2.type === "button") return "text";
    if (column2.type !== "formula") return column2.type;
    return formulaResultKind(column2.config.formula);
  }

  // shared/databaseFilters.ts
  function operatorsForColumn(column2) {
    return operatorsForType(comparableType(column2));
  }
  function operatorsForType(type) {
    switch (type) {
      case "title":
      case "rich_text":
      case "text":
      case "ai":
      case "url":
      case "email":
      case "phone":
      case "location":
      case "person":
      case "created_by":
      case "last_edited_by":
      case "unique_id":
        return ["contains", "notContains", "equals", "notEquals", "isEmpty", "notEmpty"];
      case "number":
        return ["equals", "notEquals", "gt", "gte", "lt", "lte", "isEmpty", "notEmpty"];
      case "date":
      case "time":
      case "created_time":
      case "last_edited_time":
        return ["equals", "before", "after", "isEmpty", "notEmpty"];
      case "select":
      case "status":
        return ["isAnyOf", "isNoneOf", "isEmpty", "notEmpty"];
      case "multi_select":
        return ["isAnyOf", "hasAllOf", "isNoneOf", "isEmpty", "notEmpty"];
      case "checkbox":
        return ["isChecked", "isUnchecked"];
      case "attachment":
      case "files":
      case "relation":
        return ["isEmpty", "notEmpty"];
      default:
        return [];
    }
  }
  function asArray(v) {
    return Array.isArray(v) ? v : v == null ? [] : [v];
  }
  function matchesCondition(column2, row, cond) {
    const raw = row.cells[column2.id] ?? null;
    const empty = raw == null || raw === "";
    switch (comparableType(column2)) {
      case "title":
      case "rich_text":
      case "text":
      case "ai": {
        const text = databasePropertyPlainText(column2.type, raw).toLowerCase();
        const q = String(cond.value ?? "").toLowerCase();
        switch (cond.op) {
          case "contains":
            return text.includes(q);
          case "notContains":
            return !text.includes(q);
          case "equals":
            return text === q;
          case "notEquals":
            return text !== q;
          case "isEmpty":
            return empty;
          case "notEmpty":
            return !empty;
          default:
            return true;
        }
      }
      case "number": {
        const n = decodeNumber(raw);
        const target = decodeNumber(String(cond.value ?? ""));
        switch (cond.op) {
          case "isEmpty":
            return n == null;
          case "notEmpty":
            return n != null;
          default:
            if (n == null || target == null) return false;
            switch (cond.op) {
              case "equals":
                return n === target;
              case "notEquals":
                return n !== target;
              case "gt":
                return n > target;
              case "gte":
                return n >= target;
              case "lt":
                return n < target;
              case "lte":
                return n <= target;
              default:
                return true;
            }
        }
      }
      case "date":
      case "time": {
        const v = column2.type === "date" ? databaseDateSortValue(raw) : raw ?? "";
        const target = String(cond.value ?? "");
        switch (cond.op) {
          case "isEmpty":
            return empty;
          case "notEmpty":
            return !empty;
          case "equals":
            return v === target;
          case "before":
            return !empty && v < target;
          case "after":
            return !empty && v > target;
          default:
            return true;
        }
      }
      case "select": {
        const sel = raw;
        const set = asArray(cond.value);
        switch (cond.op) {
          case "isEmpty":
            return empty;
          case "notEmpty":
            return !empty;
          case "isAnyOf":
            return sel != null && set.includes(sel);
          case "isNoneOf":
            return sel == null || !set.includes(sel);
          default:
            return true;
        }
      }
      case "multi_select": {
        const ids = decodeMultiSelect(raw);
        const set = asArray(cond.value);
        switch (cond.op) {
          case "isEmpty":
            return ids.length === 0;
          case "notEmpty":
            return ids.length > 0;
          case "isAnyOf":
            return set.some((s) => ids.includes(s));
          case "hasAllOf":
            return set.every((s) => ids.includes(s));
          case "isNoneOf":
            return !set.some((s) => ids.includes(s));
          default:
            return true;
        }
      }
      case "checkbox": {
        const checked = decodeCheckbox(raw);
        return cond.op === "isChecked" ? checked : cond.op === "isUnchecked" ? !checked : true;
      }
      case "attachment": {
        const count = (row.attachments?.[column2.id] ?? []).length;
        return cond.op === "isEmpty" ? count === 0 : cond.op === "notEmpty" ? count > 0 : true;
      }
      case "relation": {
        const count = row.relationCounts?.[column2.id] ?? 0;
        return cond.op === "isEmpty" ? count === 0 : cond.op === "notEmpty" ? count > 0 : true;
      }
      default:
        return true;
    }
  }

  // shared/databaseQuery.ts
  function assertFilterNode(value, depth = 0) {
    if (depth > 32) throw new Error("El filtro supera la profundidad m\xE1xima de 32 niveles.");
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Nodo de filtro no v\xE1lido.");
    const node = value;
    if (node.type === "condition") {
      if (typeof node.columnId !== "string" || !node.columnId) throw new Error("La condici\xF3n no indica una propiedad v\xE1lida.");
      if (typeof node.op !== "string") throw new Error("La condici\xF3n no indica un operador v\xE1lido.");
      return;
    }
    if (node.type === "group") {
      if (node.operator !== "and" && node.operator !== "or") throw new Error("El grupo no indica un operador v\xE1lido.");
      if (!Array.isArray(node.children)) throw new Error("El grupo de filtros no contiene una lista v\xE1lida.");
      if (node.children.length > 100) throw new Error("Un grupo no puede contener m\xE1s de 100 filtros.");
      for (const child of node.children) assertFilterNode(child, depth + 1);
      return;
    }
    throw new Error("Tipo de nodo de filtro desconocido.");
  }

  // shared/databaseTemporal.ts
  var DATABASE_TEMPORAL_EVENT_LIMIT = 500;
  var LOCAL_PATTERN = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?)?/;
  function localParts(value) {
    const match = LOCAL_PATTERN.exec(value);
    if (!match) return null;
    const result = {
      year: Number(match[1]),
      month: Number(match[2]),
      day: Number(match[3]),
      hour: Number(match[4] ?? 0),
      minute: Number(match[5] ?? 0),
      second: Number(match[6] ?? 0),
      includeTime: match[4] != null
    };
    const check = new Date(partsEpoch(result));
    if (check.getUTCFullYear() !== result.year || check.getUTCMonth() !== result.month - 1 || check.getUTCDate() !== result.day || result.hour > 23 || result.minute > 59 || result.second > 59) return null;
    return result;
  }
  function pad(value, width = 2) {
    return String(value).padStart(width, "0");
  }
  function formatLocal(parts, includeTime = parts.includeTime) {
    const date = `${pad(parts.year, 4)}-${pad(parts.month)}-${pad(parts.day)}`;
    return includeTime ? `${date}T${pad(parts.hour)}:${pad(parts.minute)}:${pad(parts.second)}` : date;
  }
  function formatter(timeZone) {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    });
  }
  function partsAt(epoch, timeZone) {
    const values = Object.fromEntries(formatter(timeZone).formatToParts(new Date(epoch)).map((part) => [part.type, part.value]));
    return {
      year: Number(values.year),
      month: Number(values.month),
      day: Number(values.day),
      hour: Number(values.hour),
      minute: Number(values.minute),
      second: Number(values.second),
      includeTime: true
    };
  }
  function partsEpoch(parts) {
    const date = /* @__PURE__ */ new Date(0);
    date.setUTCFullYear(parts.year, parts.month - 1, parts.day);
    date.setUTCHours(parts.hour, parts.minute, parts.second, 0);
    return date.getTime();
  }
  function sameWall(left, right) {
    return left.year === right.year && left.month === right.month && left.day === right.day && left.hour === right.hour && left.minute === right.minute && left.second === right.second;
  }
  function isValidTimeZone(timeZone) {
    try {
      formatter(timeZone).format(0);
      return true;
    } catch {
      return false;
    }
  }
  function resolveDatabaseZonedDate(local, requestedTimeZone) {
    const parsed = localParts(local);
    if (!parsed) throw new Error(`Fecha fuera de rango o no v\xE1lida: ${local}`);
    const timeZone = isValidTimeZone(requestedTimeZone) ? requestedTimeZone : "UTC";
    const naive = partsEpoch(parsed);
    const offsets = /* @__PURE__ */ new Set();
    for (const delta of [-864e5, -216e5, 0, 216e5, 864e5]) {
      const sample = naive + delta;
      offsets.add(partsEpoch(partsAt(sample, timeZone)) - sample);
    }
    const matches = [...offsets].map((offset) => naive - offset).filter((epoch) => sameWall(partsAt(epoch, timeZone), parsed)).sort((left, right) => left - right);
    if (matches.length > 0) {
      return { utc: new Date(matches[0]).toISOString(), timeZone, adjustment: matches.length > 1 ? "overlap-earlier" : "none" };
    }
    for (let minute = 1; minute <= 180; minute += 1) {
      const advanced = new Date(naive + minute * 6e4);
      const candidate = {
        year: advanced.getUTCFullYear(),
        month: advanced.getUTCMonth() + 1,
        day: advanced.getUTCDate(),
        hour: advanced.getUTCHours(),
        minute: advanced.getUTCMinutes(),
        second: advanced.getUTCSeconds(),
        includeTime: parsed.includeTime
      };
      for (const offset of offsets) {
        const epoch = partsEpoch(candidate) - offset;
        if (sameWall(partsAt(epoch, timeZone), candidate)) {
          return { utc: new Date(epoch).toISOString(), timeZone, adjustment: "gap-forward" };
        }
      }
    }
    throw new Error(`No se pudo resolver la fecha ${local} en ${timeZone}.`);
  }
  function addLocal(value, amount, unit) {
    const parts = localParts(value);
    if (!parts) throw new Error(`Fecha fuera de rango o no v\xE1lida: ${value}`);
    const date = new Date(partsEpoch(parts));
    if (unit === "hour") date.setUTCHours(date.getUTCHours() + amount);
    else if (unit === "daily") date.setUTCDate(date.getUTCDate() + amount);
    else if (unit === "weekly") date.setUTCDate(date.getUTCDate() + amount * 7);
    else if (unit === "monthly") {
      const wantedDay = date.getUTCDate();
      date.setUTCDate(1);
      date.setUTCMonth(date.getUTCMonth() + amount);
      const last = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
      date.setUTCDate(Math.min(wantedDay, last));
    } else {
      const wantedMonth = date.getUTCMonth();
      const wantedDay = date.getUTCDate();
      date.setUTCDate(1);
      date.setUTCFullYear(date.getUTCFullYear() + amount);
      date.setUTCMonth(wantedMonth);
      const last = new Date(Date.UTC(date.getUTCFullYear(), wantedMonth + 1, 0)).getUTCDate();
      date.setUTCDate(Math.min(wantedDay, last));
    }
    const next = {
      year: date.getUTCFullYear(),
      month: date.getUTCMonth() + 1,
      day: date.getUTCDate(),
      hour: date.getUTCHours(),
      minute: date.getUTCMinutes(),
      second: date.getUTCSeconds(),
      includeTime: parts.includeTime
    };
    if (next.year < 1 || next.year > 9999) throw new Error("La fecha debe estar entre los a\xF1os 0001 y 9999.");
    return formatLocal(next, parts.includeTime);
  }
  function localDurationMs(start, end) {
    const left = localParts(start);
    const right = localParts(end);
    if (!left || !right) return 0;
    return Math.max(0, partsEpoch(right) - partsEpoch(left));
  }
  function addDurationLocal(start, duration, includeTime) {
    const parsed = localParts(start);
    if (!parsed) throw new Error(`Fecha no v\xE1lida: ${start}`);
    const date = new Date(partsEpoch(parsed) + duration);
    return formatLocal({
      year: date.getUTCFullYear(),
      month: date.getUTCMonth() + 1,
      day: date.getUTCDate(),
      hour: date.getUTCHours(),
      minute: date.getUTCMinutes(),
      second: date.getUTCSeconds(),
      includeTime
    }, includeTime);
  }
  function expandDatabaseDateOccurrences(value, windowStartUtc, windowEndUtc, defaultTimeZone, limit2 = DATABASE_TEMPORAL_EVENT_LIMIT) {
    const windowStart = Date.parse(windowStartUtc);
    const windowEnd = Date.parse(windowEndUtc);
    if (!Number.isFinite(windowStart) || !Number.isFinite(windowEnd) || windowEnd <= windowStart) throw new Error("Ventana temporal no v\xE1lida.");
    const timeZone = value.timeZone || defaultTimeZone || "UTC";
    const displayDuration = localDurationMs(value.start, value.end || value.start);
    const overlapDuration = displayDuration || (value.includeTime ? 36e5 : 864e5);
    const output = [];
    let start = value.start;
    let occurrence = 0;
    const hardLimit = Math.max(1, Math.min(DATABASE_TEMPORAL_EVENT_LIMIT, Math.floor(limit2)));
    while (value.recurrence && occurrence < 1e6) {
      const resolved = resolveDatabaseZonedDate(start, timeZone);
      if (Date.parse(resolved.utc) >= windowStart - overlapDuration) break;
      occurrence += 1;
      start = addLocal(value.start, occurrence, value.recurrence);
    }
    while (output.length < hardLimit && occurrence < 1e6) {
      const end = addDurationLocal(start, displayDuration, Boolean(value.includeTime));
      const intervalEnd = value.includeTime ? addDurationLocal(start, overlapDuration, true) : addDurationLocal(end, 864e5, false);
      const resolvedStart = resolveDatabaseZonedDate(start, timeZone);
      const resolvedEnd = resolveDatabaseZonedDate(intervalEnd, timeZone);
      const startEpoch = Date.parse(resolvedStart.utc);
      const endEpoch = Date.parse(resolvedEnd.utc);
      if (startEpoch >= windowEnd) break;
      if (endEpoch > windowStart && startEpoch < windowEnd) output.push({
        start,
        end,
        startUtc: resolvedStart.utc,
        endUtc: resolvedEnd.utc,
        occurrence,
        dstAdjustment: resolvedStart.adjustment !== "none" ? resolvedStart.adjustment : resolvedEnd.adjustment
      });
      if (!value.recurrence) break;
      occurrence += 1;
      start = addLocal(value.start, occurrence, value.recurrence);
    }
    return output;
  }

  // shared/canonicalJson.ts
  function canonicalJson(value) {
    const normalize = (input) => {
      if (Array.isArray(input)) return input.map(normalize);
      if (input !== null && typeof input === "object") {
        return Object.fromEntries(Object.entries(input).filter(([, item]) => item !== void 0).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0).map(([key, item]) => [key, normalize(item)]));
      }
      return input;
    };
    return JSON.stringify(normalize(value));
  }

  // shared/databaseFormulaEval.ts
  function cellDisplayValue(column2, row) {
    const raw = row.cells[column2.id] ?? null;
    if (raw == null || raw === "") return "";
    switch (column2.type) {
      case "select":
        return column2.options.find((o) => o.id === raw)?.label ?? "";
      case "multi_select":
        return decodeMultiSelect(raw).map((id) => column2.options.find((o) => o.id === id)?.label ?? "").filter(Boolean).join(", ");
      case "checkbox":
        return decodeCheckbox(raw) ? "S\xED" : "No";
      default:
        return databasePropertyPlainText(column2.type, raw);
    }
  }
  function cellNumber(column2, row) {
    if (!column2) return null;
    const raw = row.cells[column2.id] ?? null;
    if (raw == null || raw === "") return null;
    if (column2.type === "checkbox") return decodeCheckbox(raw) ? 1 : 0;
    return decodeNumber(raw);
  }
  function lowerBound(sorted, x) {
    let lo = 0;
    let hi = sorted.length;
    while (lo < hi) {
      const mid = lo + hi >> 1;
      if (sorted[mid] < x) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }
  function upperBound(sorted, x) {
    let lo = 0;
    let hi = sorted.length;
    while (lo < hi) {
      const mid = lo + hi >> 1;
      if (sorted[mid] <= x) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }
  function median(sorted) {
    if (sorted.length === 0) return null;
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
  }
  var FLOAT_NOISE_DECIMALS = 10;
  function clean(n) {
    const f = 10 ** FLOAT_NOISE_DECIMALS;
    return Math.round(n * f) / f;
  }
  function computeColumnStats(column2, rows2) {
    const values = [];
    for (const r of rows2) {
      const n = cellNumber(column2, r);
      if (n != null) values.push(n);
    }
    values.sort((a, b) => a - b);
    const total = values.reduce((a, b) => a + b, 0);
    return { sorted: values, total, mean: values.length ? total / values.length : 0 };
  }
  function evalArithmetic(spec, columns, row) {
    const value = (o) => o.kind === "number" ? o.value : cellNumber(columns.get(o.columnId), row);
    const raw = spec.operands.map(value);
    if (spec.op === "countFilled") return raw.filter((n) => n != null).length;
    if (spec.op === "subtract" || spec.op === "divide") {
      if (raw.length === 0 || raw.some((n) => n == null)) return null;
      let acc = raw[0];
      for (const n of raw.slice(1)) {
        if (spec.op === "divide") {
          if (n === 0) return null;
          acc /= n;
        } else acc -= n;
      }
      return acc;
    }
    const nums = raw.filter((n) => n != null);
    if (nums.length === 0) return null;
    switch (spec.op) {
      case "add":
        return nums.reduce((a, b) => a + b, 0);
      case "multiply":
        return nums.reduce((a, b) => a * b, 1);
      case "average":
        return nums.reduce((a, b) => a + b, 0) / nums.length;
      case "min":
        return Math.min(...nums);
      case "max":
        return Math.max(...nums);
      case "median":
        return median([...nums].sort((a, b) => a - b));
      default:
        return null;
    }
  }
  function evalColumnStat(fn, stats, self) {
    switch (fn) {
      case "columnTotal":
        return stats.total;
      case "columnMean":
        return stats.sorted.length ? stats.mean : null;
      case "percentOfTotal":
        if (self == null || stats.total === 0) return null;
        return self / stats.total * 100;
      case "diffFromMean":
        return self == null || stats.sorted.length === 0 ? null : self - stats.mean;
      case "rank": {
        if (self == null || stats.sorted.length === 0) return null;
        return stats.sorted.length - upperBound(stats.sorted, self) + 1;
      }
      case "percentile": {
        if (self == null || stats.sorted.length === 0) return null;
        return lowerBound(stats.sorted, self) / stats.sorted.length * 100;
      }
    }
  }
  function outputValue(o, columns, row) {
    switch (o.kind) {
      case "text":
        return o.value === "" ? null : o.value;
      case "number":
        return encodeNumber(o.value);
      case "column": {
        const col = columns.get(o.columnId);
        if (!col) return null;
        const v = cellDisplayValue(col, row);
        return v === "" ? null : v;
      }
      case "empty":
        return null;
    }
  }
  function evaluateFormula(spec, row, ctx) {
    const numeric = (n) => n == null ? null : encodeNumber(clean(n));
    switch (spec.kind) {
      case "arithmetic":
        return { value: numeric(evalArithmetic(spec, ctx.columns, row)) };
      case "columnStat": {
        const col = ctx.columns.get(spec.columnId);
        const stats = ctx.stats.get(spec.columnId);
        if (!col || !stats) return { value: null };
        return { value: numeric(evalColumnStat(spec.fn, stats, cellNumber(col, row))) };
      }
      case "ifThen": {
        for (const rule of spec.rules) {
          const conds = rule.conditions.filter((c) => ctx.columns.has(c.columnId));
          if (conds.length === 0) continue;
          const results = conds.map((c) => matchesCondition(ctx.columns.get(c.columnId), row, c));
          const hit = rule.conjunction === "or" ? results.some(Boolean) : results.every(Boolean);
          if (hit) return { value: outputValue(rule.output, ctx.columns, row), color: rule.color ?? null };
        }
        return { value: outputValue(spec.otherwise, ctx.columns, row), color: spec.otherwiseColor ?? null };
      }
      case "concat": {
        const text = spec.parts.map((p) => {
          if (p.kind === "text") return p.value;
          const col = ctx.columns.get(p.columnId);
          return col ? cellDisplayValue(col, row) : "";
        }).join("");
        return { value: text.trim() === "" ? null : text };
      }
      case "expression":
        try {
          return {
            value: formulaRuntimeToRaw(evaluateFormulaExpression(spec.ast, {
              columns: ctx.columns,
              row,
              relatedValues: (relationColumnId, targetColumnId) => ctx.relatedValues?.(row.id, relationColumnId, targetColumnId) ?? [],
              columnStats: ctx.stats
            }))
          };
        } catch (error) {
          return { value: null, error: error instanceof Error ? error.message : String(error) };
        }
    }
  }
  function applyColorRules(value, kind, rules) {
    const empty = value == null || value === "";
    for (const r of rules) {
      const target = r.value ?? "";
      let hit = false;
      if (r.op === "isEmpty") hit = empty;
      else if (r.op === "notEmpty") hit = !empty;
      else if (empty) hit = false;
      else if (kind === "number") {
        const a = decodeNumber(value);
        const b = decodeNumber(String(target));
        if (a == null || b == null) hit = false;
        else if (r.op === "gt") hit = a > b;
        else if (r.op === "gte") hit = a >= b;
        else if (r.op === "lt") hit = a < b;
        else if (r.op === "lte") hit = a <= b;
        else if (r.op === "equals") hit = a === b;
        else if (r.op === "notEquals") hit = a !== b;
      } else {
        const a = String(value).toLowerCase();
        const b = String(target).toLowerCase();
        if (r.op === "equals") hit = a === b;
        else if (r.op === "notEquals") hit = a !== b;
        else if (r.op === "contains") hit = a.includes(b);
        else if (r.op === "notContains") hit = !a.includes(b);
      }
      if (hit) return r.color;
    }
    return null;
  }
  function orderFormulaColumns(columns) {
    const formulaCols = columns.filter((c) => c.type === "formula");
    const byId = new Map(formulaCols.map((c) => [c.id, c]));
    const ordered = [];
    const done = /* @__PURE__ */ new Set();
    const visiting = /* @__PURE__ */ new Set();
    const circular = /* @__PURE__ */ new Set();
    const visit = (col) => {
      if (done.has(col.id) || circular.has(col.id)) return;
      if (visiting.has(col.id)) {
        circular.add(col.id);
        return;
      }
      visiting.add(col.id);
      for (const depId of formulaDependencies(col.config.formula)) {
        const dep = byId.get(depId);
        if (dep) visit(dep);
        if (circular.has(depId)) circular.add(col.id);
      }
      visiting.delete(col.id);
      if (!circular.has(col.id)) {
        done.add(col.id);
        ordered.push(col);
      }
    };
    for (const c of formulaCols) visit(c);
    return { ordered, circular };
  }
  function computeFormulas(rows2, columns, statRows = rows2, options = {}) {
    const { ordered, circular } = orderFormulaColumns(columns);
    if (ordered.length === 0 && circular.size === 0) return;
    const byId = new Map(columns.map((c) => [c.id, c]));
    const evalRows = statRows;
    const formulaIds = [...ordered.map((column2) => column2.id), ...circular].filter((id) => !options.columnIds || options.columnIds.has(id));
    for (const row of evalRows) for (const id of formulaIds) {
      if (row.formulaErrors) delete row.formulaErrors[id];
      if (row.formulaColors) delete row.formulaColors[id];
    }
    for (const col of ordered) {
      if (options.columnIds && !options.columnIds.has(col.id)) continue;
      const spec = col.config.formula;
      const problem = validateFormula(spec, columns);
      if (problem || !spec) {
        for (const row of evalRows) {
          row.cells[col.id] = null;
          setError(row, col.id, problem ?? "Esta columna todav\xEDa no tiene f\xF3rmula.");
        }
        continue;
      }
      const colorRules = col.config.formulaColors ?? [];
      const kind = formulaResultKind(spec);
      const stats = /* @__PURE__ */ new Map();
      const statisticIds = spec.kind === "columnStat" ? [spec.columnId] : spec.kind === "expression" ? formulaExpressionGlobalStatDependencies(spec.ast) : [];
      for (const statisticId of statisticIds) {
        const src = byId.get(statisticId);
        if (src) stats.set(statisticId, computeColumnStats(src, evalRows));
      }
      const ctx = { columns: byId, stats, relatedValues: options.relatedValues };
      for (const row of evalRows) {
        const res = evaluateFormula(spec, row, ctx);
        row.cells[col.id] = res.value;
        if (res.error) setError(row, col.id, res.error);
        const color = res.color ?? applyColorRules(res.value, kind, colorRules);
        if (color) {
          row.formulaColors = row.formulaColors ?? {};
          row.formulaColors[col.id] = color;
        }
      }
    }
    for (const colId of circular) {
      if (options.columnIds && !options.columnIds.has(colId)) continue;
      for (const row of evalRows) {
        row.cells[colId] = null;
        setError(row, colId, "Referencia circular: la f\xF3rmula se usa a s\xED misma.");
      }
    }
    if (evalRows !== rows2) {
      const source = new Map(evalRows.map((r) => [r.id, r]));
      for (const row of rows2) {
        const src = source.get(row.id);
        if (!src) continue;
        for (const id of formulaIds) {
          row.cells[id] = src.cells[id] ?? null;
          if (row.formulaColors) delete row.formulaColors[id];
          if (row.formulaErrors) delete row.formulaErrors[id];
          if (src.formulaColors?.[id]) (row.formulaColors ?? (row.formulaColors = {}))[id] = src.formulaColors[id];
          if (src.formulaErrors?.[id]) (row.formulaErrors ?? (row.formulaErrors = {}))[id] = src.formulaErrors[id];
        }
      }
    }
  }
  function setError(row, columnId, message) {
    row.formulaErrors = row.formulaErrors ?? {};
    row.formulaErrors[columnId] = message;
  }

  // shared/companionDatabaseDerived.ts
  function prepareCompanionDatabaseDerived(root) {
    const captured = new Map([[root.databaseId, root], ...Object.entries(root.relatedSources ?? {})]);
    if (![...captured.values()].some((source2) => source2.localChanges)) return root;
    const sources = new Map([...captured].map(([id, source2]) => {
      if (source2.version !== 1 || source2.vaultId !== root.vaultId || source2.databaseId !== id || source2.database.id !== id) throw new Error("Una dependencia de c\xE1lculo no pertenece a esta copia.");
      return [id, { ...source2, rows: source2.rows.map((row) => ({ ...row, cells: { ...row.cells }, rollups: { ...row.rollups }, formulaColors: { ...row.formulaColors }, formulaErrors: { ...row.formulaErrors } })) }];
    }));
    const source = sources.get(root.databaseId);
    for (const current of sources.values()) if (current.localChanges) for (const row of current.rows) for (const column2 of current.columns) {
      if (column2.type === "created_time") row.cells[column2.id] = row.createdAt;
      if (column2.type === "last_edited_time") row.cells[column2.id] = row.updatedAt;
      if (column2.type === "created_by") row.cells[column2.id] = row.createdBy ?? "";
      if (column2.type === "last_edited_by") row.cells[column2.id] = row.updatedBy ?? "";
      if (column2.type === "unique_id") row.cells[column2.id] = String(column2.config.uniqueIdPrefix ?? "").slice(0, 24) + String(row.uniqueSequence ?? 0).padStart(Math.min(12, Math.max(1, Math.trunc(Number(column2.config.uniqueIdPadding ?? 4)))), "0");
    }
    const state = /* @__PURE__ */ new Map();
    const circular = new Map([...sources].map(([id, current]) => [id, orderFormulaColumns(current.columns).circular]));
    const target = (current, relationId, columnId) => {
      const relation = current.columns.find((column3) => column3.id === relationId);
      if (relation?.type !== "relation" || relation.config.relationTargetKind !== "db_row" || !relation.config.relationTargetDatabaseId) return null;
      const related = sources.get(relation.config.relationTargetDatabaseId);
      if (!related) throw new Error("Falta una dependencia de c\xE1lculo en la descarga. Renueva la copia completa.");
      const column2 = !columnId || columnId === "__title__" ? related.columns.find((column3) => column3.type === "title") ?? related.columns[0] : related.columns.find((column3) => column3.id === columnId);
      return { source: related, column: column2, relation };
    };
    const ids = (current, rowId, columnId, rollup = false) => {
      if (!current.relations) return current.dependencies[rowId]?.[columnId] ?? [];
      return current.relations.filter((row) => row.row_id === rowId && row.column_id === columnId && row.target_kind === "db_row").slice().sort((a, b) => a.position - b.position || (rollup ? compare(a.created_at, b.created_at) : 0) || compare(a.id, b.id)).map((row) => row.target_id);
    };
    const relatedValues = (current, rowId, relationId, columnId) => {
      const related = target(current, relationId, columnId);
      if (!related?.column) return [];
      const values = new Map(related.source.rows.map((row) => [row.id, row.cells[related.column.id] ?? null]));
      return ids(current, rowId, relationId).flatMap((id) => {
        const raw = values.get(id) ?? null;
        if (raw == null) return [];
        if (["number", "formula", "rollup"].includes(related.column.type)) {
          const numeric = Number(raw.replace(/%$/, ""));
          return [Number.isFinite(numeric) ? numeric : raw];
        }
        return related.column.type === "checkbox" ? [raw === "1" || raw === "true"] : [raw];
      });
    };
    const evaluate = (current, column2) => {
      if (!["formula", "rollup"].includes(column2.type)) return;
      const key = current.databaseId + ":" + column2.id;
      if (state.get(key) === "done") return;
      if (column2.type === "formula" && circular.get(current.databaseId)?.has(column2.id)) {
        computeFormulas(current.rows, current.columns, current.rows, { columnIds: /* @__PURE__ */ new Set([column2.id]) });
        state.set(key, "done");
        return;
      }
      if (state.get(key) === "visiting") throw new Error("Las propiedades calculadas contienen una referencia circular. Revisa su configuraci\xF3n en Nodus.");
      state.set(key, "visiting");
      if (column2.type === "rollup") {
        const related = target(current, column2.config.rollupRelationColumnId, column2.config.rollupTargetColumnId);
        if (related?.column) evaluate(related.source, related.column);
        const values = new Map(related?.source.rows.map((row) => [row.id, related.column ? row.cells[related.column.id] ?? null : null]) ?? []);
        const labels = new Map(related?.column?.options.map((option) => [option.id, option.label]) ?? []);
        for (const row of current.rows) {
          const display = related ? ids(current, row.id, related.relation.id, true).map((id) => {
            const raw = values.get(id) ?? null;
            if (raw == null) return null;
            if (related.column?.type === "select") return labels.get(raw) ?? raw;
            if (related.column?.type === "multi_select") return decodeMultiSelect(raw).map((id2) => labels.get(id2) ?? id2).join(", ");
            return raw;
          }) : [];
          const value = related ? aggregateRollup(column2.config.rollupFunction ?? "show", display) : "";
          (row.rollups ?? (row.rollups = {}))[column2.id] = value;
          row.cells[column2.id] = value === "" ? null : value;
        }
      } else {
        const formula = column2.config.formula;
        for (const id of formulaDependencies(formula)) {
          const dependency = current.columns.find((column3) => column3.id === id);
          if (dependency) evaluate(current, dependency);
        }
        if (formula?.kind === "expression") for (const pair of formulaExpressionRelations(formula.ast)) {
          const related = target(current, pair.relationColumnId, pair.targetColumnId);
          if (related?.column) evaluate(related.source, related.column);
        }
        computeFormulas(current.rows, current.columns, current.rows, { columnIds: /* @__PURE__ */ new Set([column2.id]), relatedValues: (rowId, relationId, columnId) => relatedValues(current, rowId, relationId, columnId) });
      }
      state.set(key, "done");
    };
    for (const current of sources.values()) for (const column2 of current.columns) evaluate(current, column2);
    return { ...source, relatedSources: Object.fromEntries([...sources].filter(([id]) => id !== root.databaseId)) };
  }
  function compare(left, right) {
    return left < right ? -1 : left > right ? 1 : 0;
  }

  // shared/companionDatabasePresentation.ts
  function filtered(source, filter) {
    if (filter) assertFilterNode(filter);
    const columns = new Map(source.columns.map((column2) => [column2.id, column2]));
    const validate = (node) => {
      if (node.type === "group") {
        node.children.forEach(validate);
        return;
      }
      const column2 = columns.get(node.columnId);
      if (!column2 || !operatorsForColumn(column2).includes(node.op)) throw new Error("El filtro no corresponde a una propiedad de esta vista.");
    };
    if (filter) validate(filter);
    const active = (node) => node.type === "condition" || node.children.some(active);
    const matches = (row, node) => {
      if (node.type === "group") {
        const children = node.children.filter(active);
        return !children.length || (node.operator === "and" ? children.every((child) => matches(row, child)) : children.some((child) => matches(row, child)));
      }
      const column2 = columns.get(node.columnId);
      if (!column2) throw new Error("La propiedad del filtro ya no existe.");
      if (!operatorsForColumn(column2).includes(node.op)) throw new Error("El filtro no corresponde a esta propiedad.");
      return sqliteCondition(column2, row, node);
    };
    return filter ? source.rows.filter((row) => matches(row, filter)) : source.rows.slice();
  }
  function column(source, id, type) {
    const value = source.columns.find((column2) => column2.id === id);
    if (!value || type && value.type !== type) throw new Error("La vista hace referencia a una propiedad que ya no existe.");
    return value;
  }
  function limit(value, maximum) {
    if (value != null && (!Number.isFinite(value) || value < 1)) throw new Error("L\xEDmite de consulta no v\xE1lido.");
    return Math.max(1, Math.min(maximum, Math.floor(value ?? maximum)));
  }
  function number(raw) {
    if (raw == null) return null;
    const prefix = raw.trimStart().match(/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/);
    return prefix ? Number(prefix[0]) : 0;
  }
  function label(column2, raw) {
    if (!raw) return "Sin valor";
    if (["select", "status"].includes(column2.type)) return column2.options.find((option) => option.id === raw)?.label ?? raw;
    if (column2.type === "checkbox") return raw === "1" || raw === "true" ? "S\xED" : "No";
    if (column2.type === "date") return decodeDatabaseDate(raw)?.start ?? raw;
    return raw;
  }
  function drilldown(column2, raw) {
    if (!raw) return { type: "condition", columnId: column2.id, op: "isEmpty", value: null };
    const operators = operatorsForColumn(column2);
    if (operators.includes("isAnyOf")) return { type: "condition", columnId: column2.id, op: "isAnyOf", value: [raw] };
    if (operators.includes("equals")) return { type: "condition", columnId: column2.id, op: "equals", value: raw };
    if (operators.includes("isChecked")) return { type: "condition", columnId: column2.id, op: raw === "1" || raw === "true" ? "isChecked" : "isUnchecked", value: null };
    return { type: "condition", columnId: column2.id, op: "notEmpty", value: null };
  }
  var binary = (left, right) => {
    const a = Array.from(left), b = Array.from(right);
    for (let index = 0; index < Math.min(a.length, b.length); index++) {
      const difference = a[index].codePointAt(0) - b[index].codePointAt(0);
      if (difference) return difference;
    }
    return a.length - b.length;
  };
  var sqliteLower = (value) => value.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
  function sqliteCondition(column2, row, node) {
    const raw = row.cells[column2.id] ?? null, type = comparableType(column2), empty = raw == null || raw === "";
    const metadata = ["created_time", "last_edited_time", "created_by", "last_edited_by", "unique_id"].includes(column2.type);
    if (type === "attachment" || type === "relation") {
      const count = type === "attachment" ? row.attachments?.[column2.id]?.length ?? 0 : row.relationCounts?.[column2.id] ?? 0;
      return node.op === "isEmpty" ? count === 0 : count > 0;
    }
    if (node.op === "isEmpty") return empty;
    if (node.op === "notEmpty") return !empty;
    if (type === "title" || type === "text" || type === "ai") {
      const target = String(node.value ?? "").toLocaleLowerCase(), haystack = raw == null ? null : sqliteLower(raw);
      const match = haystack != null && (node.op === "contains" || node.op === "notContains" ? haystack.includes(target) : haystack === target);
      return node.op === "notContains" || node.op === "notEquals" ? metadata ? haystack != null && !match : !match : match;
    }
    if (type === "number") {
      const value = number(raw), target = Number(node.value);
      if (value == null || !Number.isFinite(target)) return false;
      switch (node.op) {
        case "equals":
          return value === target;
        case "notEquals":
          return value !== target;
        case "gt":
          return value > target;
        case "gte":
          return value >= target;
        case "lt":
          return value < target;
        case "lte":
          return value <= target;
        default:
          return false;
      }
    }
    if (type === "date" || type === "time") {
      let value = raw;
      if (!metadata && raw) {
        try {
          const json = JSON.parse(raw);
          value = typeof json?.start === "string" ? json.start : null;
        } catch {
        }
      }
      if (value == null) return false;
      const compare2 = binary(value, String(node.value ?? ""));
      return node.op === "before" ? compare2 < 0 : node.op === "after" ? compare2 > 0 : compare2 === 0;
    }
    if (type === "checkbox") {
      const checked = raw != null && Math.trunc(number(raw) ?? 0) === 1;
      return node.op === "isUnchecked" ? !checked : checked;
    }
    const values = (Array.isArray(node.value) ? node.value : node.value == null ? [] : [node.value]).map(String);
    if (type === "select") {
      const match = raw != null && values.includes(raw);
      return node.op === "isNoneOf" ? !match : match;
    }
    if (type === "multi_select") {
      let json = [];
      try {
        json = JSON.parse(raw ?? "[]");
      } catch {
      }
      const items = (Array.isArray(json) ? json : json && typeof json === "object" ? Object.values(json) : [json]).map((value) => typeof value === "boolean" ? value ? "1" : "0" : value == null ? "" : typeof value === "object" ? JSON.stringify(value) : String(value));
      const match = values.some((value) => items.includes(value));
      return node.op === "hasAllOf" ? values.every((value) => items.includes(value)) : node.op === "isNoneOf" ? !match : match;
    }
    return true;
  }
  function sqliteRowsOrder(source, rows2, rules, rowSort, omitPosition) {
    const resolved = rules.map((rule) => ({ ...rule, column: column(source, rule.columnId) }));
    function key(column2, row) {
      const raw = row.cells[column2.id] ?? "", type = comparableType(column2);
      if (column2.type === "unique_id") return row.uniqueSequence ?? 0;
      if (type === "number") return number(raw) ?? 0;
      if (type === "checkbox") return Math.trunc(number(raw) ?? 0);
      if (type === "select") return column2.options.find((option) => option.id === raw)?.position ?? 2147483647;
      if (type === "date" || type === "time") {
        try {
          const json = JSON.parse(raw);
          return typeof json?.start === "string" ? json.start : "";
        } catch {
          return raw;
        }
      }
      return sqliteLower(raw);
    }
    return rows2.sort((a, b) => {
      for (const rule of resolved) {
        const left = a.cells[rule.column.id], right = b.cells[rule.column.id], emptyLeft = left == null || left === "", emptyRight = right == null || right === "";
        if (emptyLeft !== emptyRight) return emptyLeft ? 1 : -1;
        const x = key(rule.column, a), y = key(rule.column, b), difference = typeof x === "number" && typeof y === "number" ? x - y : binary(String(x), String(y));
        if (difference) return rule.dir === "desc" ? -difference : difference;
      }
      if (!rules.length && rowSort && rowSort !== "position") {
        const difference = rowSort === "createdAsc" ? binary(a.createdAt, b.createdAt) : rowSort === "createdDesc" ? binary(b.createdAt, a.createdAt) : binary(b.updatedAt, a.updatedAt);
        if (difference) return difference;
      } else if (!omitPosition && a.position !== b.position) return a.position - b.position;
      return binary(a.id, b.id);
    });
  }
  function title(source, row) {
    const id = source.columns.find((column2) => column2.type === "title")?.id;
    return (id ? row.cells[id] : null) || "Sin t\xEDtulo";
  }
  function chart(source, input) {
    const x = column(source, input.xColumnId), y = input.yColumnId ? column(source, input.yColumnId) : null, series = input.seriesColumnId ? column(source, input.seriesColumnId) : null;
    if (input.aggregation !== "count" && !y) throw new Error("Esta agregaci\xF3n necesita un eje Y.");
    const groups = /* @__PURE__ */ new Map();
    for (const row of filtered(source, input.filter)) {
      const key = row.cells[x.id] ?? "", seriesKey = series ? row.cells[series.id] ?? "" : "", identity = JSON.stringify([key, seriesKey]);
      const group = groups.get(identity) ?? { x: key, series: seriesKey, count: 0, ys: [], xs: [] };
      group.count++;
      const yValue = y ? number(row.cells[y.id]) : null, xValue = number(row.cells[x.id]);
      if (yValue != null) group.ys.push(yValue);
      if (xValue != null) group.xs.push(xValue);
      groups.set(identity, group);
    }
    const average = (values) => values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
    let points = [...groups.values()].map((group) => {
      const clauses = [drilldown(x, group.x), ...series ? [drilldown(series, group.series)] : []];
      const value = input.aggregation === "count" ? group.count : input.aggregation === "sum" ? group.ys.reduce((a, b) => a + b, 0) : input.aggregation === "average" ? average(group.ys) ?? 0 : input.aggregation === "min" ? group.ys.length ? group.ys.reduce((a, b) => Math.min(a, b)) : 0 : group.ys.length ? group.ys.reduce((a, b) => Math.max(a, b)) : 0;
      return { key: group.x, label: label(x, group.x), seriesKey: group.series, seriesLabel: series ? label(series, group.series) : "", value, rowCount: group.count, xNumber: average(group.xs), yNumber: average(group.ys), drilldownFilter: clauses.length === 1 ? clauses[0] : { type: "group", operator: "and", children: clauses } };
    });
    const ordered = ["line", "area", "scatter"].includes(input.type);
    points.sort((a, b) => (ordered ? 0 : b.value - a.value) || binary(a.key, b.key) || binary(a.seriesKey, b.seriesKey));
    const maximum = limit(input.limit, 200), totalGroups = points.length;
    points = points.slice(0, maximum);
    return { points, totalGroups, truncated: totalGroups > maximum, revision: source.revision, nullRows: points.filter((point) => point.key === "").reduce((sum, point) => sum + point.rowCount, 0) };
  }
  function map(source, input) {
    const location = column(source, input.locationColumnId, "location");
    const candidates = filtered(source, input.filter).sort((a, b) => a.position - b.position || binary(a.id, b.id));
    const markers = [];
    for (const row of candidates) {
      let value;
      try {
        value = JSON.parse(row.cells[location.id] ?? "null");
      } catch {
        continue;
      }
      if (!value || typeof value.latitude !== "number" || typeof value.longitude !== "number" || !Number.isFinite(value.latitude) || !Number.isFinite(value.longitude) || Math.abs(value.latitude) > 90 || Math.abs(value.longitude) > 180) continue;
      const rowTitle = title(source, row);
      markers.push({ id: `marker:${row.id}`, rowId: row.id, title: rowTitle, name: value.name || rowTitle || "Ubicaci\xF3n", latitude: value.latitude, longitude: value.longitude });
    }
    const maximum = limit(input.limit, 500);
    return { markers: markers.slice(0, maximum), totalCount: markers.length, truncated: markers.length > maximum, revision: source.revision };
  }
  function feed(source, input) {
    const date = input.dateColumnId ? column(source, input.dateColumnId, "date") : null;
    const items = [];
    for (const row of filtered(source, input.filter)) {
      const page = source.pages[row.id], raw = date ? row.cells[date.id] ?? "" : null;
      let occurredAt = raw ?? (input.includePageChanges === false ? row.createdAt : page?.updatedAt ?? row.updatedAt);
      if (date && raw) {
        try {
          const json = JSON.parse(raw);
          occurredAt = typeof json?.start === "string" ? json.start : "";
        } catch {
          occurredAt = raw;
        }
      }
      if (!occurredAt) continue;
      const kind = date ? "date" : (page?.updatedAt ?? row.updatedAt) === row.createdAt ? "created" : "edited";
      const titleId = source.columns.find((column2) => column2.type === "title")?.id;
      const rowTitle = (titleId ? row.cells[titleId] : null) ?? page?.title;
      items.push({ id: `feed:${kind}:${row.id}:${occurredAt}`, rowId: row.id, pageId: page?.id ?? null, title: rowTitle || "Sin t\xEDtulo", occurredAt, kind, actor: row.updatedBy ?? "", summary: kind === "date" ? "Fecha de la p\xE1gina" : kind === "created" ? "P\xE1gina creada" : "P\xE1gina actualizada" });
    }
    items.sort((a, b) => binary(b.occurredAt, a.occurredAt) || binary(a.rowId, b.rowId));
    const maximum = limit(input.limit, 200);
    return { items: items.slice(0, maximum), totalCount: items.length > maximum ? maximum + 1 : items.length, truncated: items.length > maximum, revision: source.revision };
  }
  function temporal(source, input) {
    const start = column(source, input.startColumnId, "date"), end = input.endColumnId ? column(source, input.endColumnId, "date") : null;
    if (input.dependencyColumnId) column(source, input.dependencyColumnId, "relation");
    const from = Date.parse(input.windowStart), to = Date.parse(input.windowEnd);
    if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) throw new Error("Ventana temporal no v\xE1lida.");
    const coarseStart = new Date(from - 2 * 864e5).toISOString().slice(0, 19), coarseEnd = new Date(to + 2 * 864e5).toISOString().slice(0, 19);
    const candidates = filtered(source, input.filter).flatMap((row) => {
      const value = decodeDatabaseDate(row.cells[start.id] ?? null);
      if (!value) return [];
      if (end) value.end = decodeDatabaseDate(row.cells[end.id] ?? null)?.start ?? value.end;
      return value.start < coarseEnd && (value.recurrence || (value.end ?? value.start) >= coarseStart) ? [{ row, value }] : [];
    }).sort((a, b) => binary(a.value.start, b.value.start) || binary(a.row.id, b.row.id));
    const maximum = limit(input.limit, 500), sourceLimit = Math.max(2e3, maximum * 4), occurrenceLimit = Math.min(maximum + 1, Math.max(2, Math.ceil((to - from) / 864e5) + 3));
    const events = [];
    let truncated = candidates.length > sourceLimit;
    const order = (a, b) => Date.parse(a.startUtc) - Date.parse(b.startUtc) || Date.parse(a.endUtc) - Date.parse(b.endUtc) || a.sourceRowId.localeCompare(b.sourceRowId);
    for (const { row, value } of candidates.slice(0, sourceLimit)) {
      try {
        for (const occurrence of expandDatabaseDateOccurrences(value, input.windowStart, input.windowEnd, input.timeZone, occurrenceLimit)) events.push({ id: `${row.id}:${occurrence.occurrence}`, sourceRowId: row.id, title: title(source, row).trim() || "Sin t\xEDtulo", start: occurrence.start, end: occurrence.end, startUtc: occurrence.startUtc, endUtc: occurrence.endUtc, includeTime: Boolean(value.includeTime), timeZone: value.timeZone || input.timeZone || "UTC", recurrence: value.recurrence ?? null, occurrence: occurrence.occurrence, dstAdjustment: occurrence.dstAdjustment, dependencies: input.dependencyColumnId ? source.dependencies[row.id]?.[input.dependencyColumnId] ?? [] : [], rowRevision: row.revision });
      } catch {
      }
      if (events.length > maximum) {
        truncated = true;
        events.sort(order);
        events.splice(maximum);
      }
    }
    events.sort(order);
    return { events, revision: source.revision, truncated, sourceRowsScanned: Math.min(candidates.length, sourceLimit), windowStart: input.windowStart, windowEnd: input.windowEnd };
  }
  async function rows(source, input, all = false) {
    const view = input.viewId ? source.views.find((view2) => view2.id === input.viewId) : null;
    if (input.viewId && !view) throw new Error("La vista guardada ya no existe.");
    const filter = input.filter === void 0 ? view?.config.filter : input.filter, sorts = input.sorts ?? view?.config.sorts ?? [];
    const identity = { databaseId: source.databaseId, revision: source.revision, localRevision: source.localRevision ?? null, filter: filter ?? null, sorts, groups: input.groups ?? view?.config.groups ?? [], rowSort: input.rowSort ?? "position" };
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson(identity)));
    const queryHash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const rules = identity.groups.map((group) => ({ columnId: group.columnId, dir: group.dir ?? "asc" }));
    for (const sort of sorts) if (!rules.some((rule) => rule.columnId === sort.columnId)) rules.push(sort);
    const condition = filter?.type === "condition" ? filter : filter?.type === "group" && filter.operator === "and" && filter.children.length === 1 && filter.children[0].type === "condition" ? filter.children[0] : null;
    const fast = condition && source.columns.find((column2) => column2.id === condition.columnId)?.type === "number" && ["equals", "notEquals", "gt", "gte", "lt", "lte"].includes(condition.op) && Number.isFinite(Number(condition.value)) && identity.groups.length === 0 && rules.length === 1 && rules[0].columnId === condition.columnId;
    const ordered = sqliteRowsOrder(source, filtered(source, filter), rules, input.rowSort, Boolean(fast));
    const maximum = all ? ordered.length : limit(input.limit, 500);
    let offset = 0;
    if (input.cursor) {
      let decoded;
      try {
        decoded = JSON.parse(atob(input.cursor));
      } catch {
        throw new Error("Cursor descargado no v\xE1lido.");
      }
      if (decoded.v !== 1 || decoded.queryHash !== queryHash || !Number.isSafeInteger(decoded.offset) || decoded.offset < 0 || decoded.offset > ordered.length) throw new Error("La consulta descargada ha cambiado.");
      offset = decoded.offset;
    }
    if (input.direction === "backward") offset = Math.max(0, offset - maximum);
    const cursor = (offset2) => btoa(JSON.stringify({ v: 1, queryHash, offset: offset2 }));
    const part = ordered.slice(offset, offset + maximum), hasMore = offset + part.length < ordered.length;
    return { rows: part, nextCursor: hasMore ? cursor(offset + part.length) : null, previousCursor: offset > 0 ? cursor(offset) : null, totalCount: ordered.length, revision: source.revision, queryHash, hasMore };
  }
  async function queryCompanionDatabasePresentation(source, action, input) {
    if (source.version !== 1 || source.databaseId !== input.databaseId || source.database.id !== source.databaseId) throw new Error("La copia no pertenece a esta base de datos.");
    source = prepareCompanionDatabaseDerived(source);
    switch (action) {
      case "metadata":
        return { database: source.database, columns: source.columns, views: source.views, revision: source.revision, columnRevisions: source.columnRevisions ?? {} };
      case "rows":
        return rows(source, input);
      case "allRows":
        return rows(source, input, true);
      case "chart":
        return chart(source, input);
      case "map":
        return map(source, input);
      case "feed":
        return feed(source, input);
      case "temporal":
        return temporal(source, input);
      default:
        throw new Error("Consulta de base de datos no disponible.");
    }
  }

  // shared/companionDatabaseContainer.ts
  async function queryCompanionDatabaseContainer(input) {
    if (input.version !== 1 || !input.vaultId || !input.viewId || input.definition.viewId !== input.viewId) throw new Error("La copia no corresponde a esta vista.");
    if (input.localFilter) assertFilterNode(input.localFilter);
    const definition = input.definition, primary = definition.sources.find((source) => source.primary) ?? definition.sources[0];
    if (!primary) throw new Error("Esta vista no tiene una fuente primaria.");
    const view = input.sources[primary.databaseId]?.views.find((view2) => view2.id === input.viewId);
    if (!view) throw new Error("La configuraci\xF3n guardada no est\xE1 incluida en la copia. Actualiza la descarga.");
    if (view.databaseId !== primary.databaseId || definition.revision !== view.revision + definition.sources.reduce((sum, source) => sum + source.revision, 0)) throw new Error("La vista cambi\xF3 durante la descarga. Actualiza la copia completa.");
    const inverse = new Map(Object.entries(primary.propertyMap).map(([canonical, column2]) => [column2, canonical]));
    const sources = input.sourceId ? definition.sources.filter((source) => source.sourceId === input.sourceId) : definition.sources;
    if (input.sourceId && !sources.length) throw new Error("La fuente no pertenece a esta vista.");
    const rows2 = [];
    const revisions = [];
    for (const source of sources) {
      const captured = input.sources[source.databaseId];
      if (!captured || captured.vaultId !== input.vaultId || captured.databaseId !== source.databaseId) throw new Error("Falta una fuente vinculada en la copia. Descarga de nuevo la vista completa.");
      const columns = new Set(captured.columns.map((column2) => column2.id));
      if (Object.values(source.propertyMap).some((column2) => !columns.has(column2))) throw new Error("Las propiedades vinculadas cambiaron durante la descarga. Actualiza la copia completa.");
      const translated = combinedDatabaseContainerFilter(view.config.filter, input.localFilter, source, inverse);
      revisions.push([source.sourceId, source.revision, captured.revision, captured.localRevision ?? null]);
      if (translated.kind === "false") continue;
      const sorts = view.config.sorts.flatMap((sort) => {
        const canonical = inverse.get(sort.columnId) ?? sort.columnId, columnId = source.propertyMap[canonical];
        return columnId ? [{ columnId, dir: sort.dir }] : [];
      });
      const page = await queryCompanionDatabasePresentation(captured, "allRows", { databaseId: source.databaseId, filter: translated.kind === "node" ? translated.node : null, sorts });
      if (!("rows" in page)) throw new Error("Respuesta de filas no v\xE1lida.");
      for (const row of page.rows) {
        const cells = {}, formulaErrors = {}, formulaColors = {};
        for (const [canonical, columnId] of Object.entries(source.propertyMap)) {
          cells[canonical] = row.cells[columnId] ?? row.rollups?.[columnId] ?? null;
          if (row.formulaErrors?.[columnId]) formulaErrors[canonical] = row.formulaErrors[columnId];
          if (row.formulaColors?.[columnId]) formulaColors[canonical] = row.formulaColors[columnId];
        }
        rows2.push({
          id: `${source.sourceId}:${row.id}`,
          sourceId: source.sourceId,
          databaseId: source.databaseId,
          rowId: row.id,
          sourceName: source.alias,
          cells,
          formulaErrors,
          formulaColors,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          revision: row.revision ?? 1
        });
      }
    }
    const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson({ definition, revisions, sourceId: input.sourceId ?? null, localFilter: input.localFilter ?? null })));
    const revision = "offline:" + Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, "0")).join("");
    return { version: 1, vaultId: input.vaultId, viewId: input.viewId, definition, rows: rows2, revision };
  }
  return __toCommonJS(companionDatabaseContainer_exports);
})();
