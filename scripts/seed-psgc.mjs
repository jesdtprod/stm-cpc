// Loads the Philippine Standard Geographic Code (regions, provinces, cities/municipalities,
// barangays) into public.psgc_areas on the linked Supabase project. Public reference data only.
// Source: https://psgc.gitlab.io/api (a mirror of the PSA PSGC publication).
// Idempotent: re-running updates changed names and parents and leaves everything else alone.
// Run: deno task db:seed-psgc [--dry-run]
//   --dry-run  downloads and validates, prints the counts, writes nothing to the database.

const BASE = "https://psgc.gitlab.io/api";
const CHUNK = 1500;
const dryRun = Deno.args.includes("--dry-run");

async function get(name) {
  const res = await fetch(`${BASE}/${name}.json`);
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
  return await res.json();
}

const [regions, provinces, cities, barangays] = await Promise.all([
  get("regions"),
  get("provinces"),
  get("cities-municipalities"),
  get("barangays"),
]);

// The API uses `false` for "not applicable".
const val = (x) => (x ? String(x) : null);

const rows = [];
for (const r of regions) {
  rows.push({
    code: r.code,
    level: "region",
    name: r.name,
    parent: null,
    region: r.code,
    province: null,
    isCity: false,
  });
}
for (const p of provinces) {
  rows.push({
    code: p.code,
    level: "province",
    name: p.name,
    parent: p.regionCode,
    region: p.regionCode,
    province: p.code,
    isCity: false,
  });
}
for (const c of cities) {
  rows.push({
    code: c.code,
    level: "city_muni",
    name: c.name,
    parent: val(c.provinceCode) ?? c.regionCode,
    region: c.regionCode,
    province: val(c.provinceCode),
    isCity: Boolean(c.isCity),
  });
}
for (const b of barangays) {
  rows.push({
    code: b.code,
    level: "barangay",
    name: b.name,
    parent: val(b.cityCode) ?? val(b.municipalityCode),
    region: b.regionCode,
    province: val(b.provinceCode),
    isCity: false,
  });
}

// Validate before touching the database.
const codes = new Set();
for (const r of rows) {
  if (!/^[0-9]{9}$/.test(r.code)) throw new Error(`bad code ${r.code}`);
  if (codes.has(r.code)) throw new Error(`duplicate code ${r.code}`);
  codes.add(r.code);
  // deno-lint-ignore no-control-regex
  if (!r.name || /[\u0000-\u001f]/.test(r.name)) {
    throw new Error(`bad name for ${r.code}`);
  }
}
for (const r of rows) {
  if (r.level !== "region" && !codes.has(r.parent)) {
    throw new Error(`${r.code} has an unknown parent ${r.parent}`);
  }
  if (!codes.has(r.region)) throw new Error(`${r.code} has an unknown region`);
}
const counts = Object.groupBy(rows, (r) => r.level);
const summary = Object.entries(counts).map(([k, v]) => `${k} ${v.length}`)
  .join(", ");
console.log(`downloaded and validated: ${rows.length} areas (${summary})`);
if (dryRun) Deno.exit(0);

const q = (s) => (s === null ? "NULL" : `'${s.replaceAll("'", "''")}'`);
const sqlFor = (chunk) =>
  `insert into public.psgc_areas (org_id, code, level, name, parent_code, region_code, province_code, is_city)
select o.id, v.code, v.level, v.name, v.parent_code, v.region_code, v.province_code, v.is_city::boolean
from public.orgs o
cross join (values
${
    chunk.map((r) =>
      `(${q(r.code)}, ${q(r.level)}, ${q(r.name)}, ${q(r.parent)}, ${
        q(r.region)
      }, ${q(r.province)}, '${r.isCity}')`
    ).join(",\n")
  }
) as v(code, level, name, parent_code, region_code, province_code, is_city)
where o.code = 'cpc' and o.deleted_at is null
on conflict (org_id, code) do update set
  level = excluded.level, name = excluded.name, parent_code = excluded.parent_code,
  region_code = excluded.region_code, province_code = excluded.province_code, is_city = excluded.is_city
where (psgc_areas.level, psgc_areas.name, psgc_areas.parent_code, psgc_areas.region_code, psgc_areas.province_code, psgc_areas.is_city)
  is distinct from (excluded.level, excluded.name, excluded.parent_code, excluded.region_code, excluded.province_code, excluded.is_city);`;

await Deno.mkdir("supabase/.temp", { recursive: true });
let done = 0;
for (let i = 0; i < rows.length; i += CHUNK) {
  const file = "supabase/.temp/psgc-chunk.sql";
  await Deno.writeTextFile(file, sqlFor(rows.slice(i, i + CHUNK)));
  // The CLI sometimes times out reaching the API; every chunk is idempotent, so retry it.
  for (let attempt = 1;; attempt++) {
    const { code, stderr } = await new Deno.Command("npx", {
      args: [
        "supabase@2.118.0",
        "db",
        "query",
        "--linked",
        "-f",
        file,
        "-o",
        "json",
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (code === 0) break;
    console.error(new TextDecoder().decode(stderr));
    if (attempt === 3) throw new Error(`chunk starting at row ${i} failed`);
  }
  done += Math.min(CHUNK, rows.length - i);
  console.log(`loaded ${done}/${rows.length}`);
}
console.log("done");
