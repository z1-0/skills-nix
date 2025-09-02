import { fetchSkills } from "../lib/skills-api.js";
import { withGet } from "../lib/handler.js";

async function fetchAllSkills() {
  const allSkills = [];
  let page = 0;
  let hasMore = true;

  while (hasMore) {
    const res = await fetchSkills(
      `skills?view=all-time&page=${page}&per_page=500`,
    );
    if (!res.ok) throw new Error(`API error: ${res.status}`);
    const data = await res.json();
    allSkills.push(...data.data);
    hasMore = data.pagination.hasMore;
    page++;
  }
  return allSkills;
}

export default withGet(async (req, res) => {
  const skills = await fetchAllSkills();
  const repos = [
    ...new Set(
      skills.filter((s) => s.sourceType === "github").map((s) => s.source),
    ),
  ];

  res.setHeader("Content-Type", "application/json");
  res.status(200).json({
    updatedAt: new Date().toISOString(),
    totalSkills: skills.length,
    uniqueRepos: repos.length,
    repos,
  });
});
