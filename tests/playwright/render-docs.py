"""Render repo markdown to HTML next to the source (so relative links resolve) for a Playwright check."""
import markdown, sys, os, re, json
repo, outlist = sys.argv[1], sys.argv[2]
docs = ["docs/runbooks/STAGED-DEPLOYMENT-V2.md", "docs/STAGED-STDV2-RUNS-2026-10-20.md", "docs/STAGED-LIVE-RUN-2026-10-20.md"]
made = []
for d in docs:
    src = os.path.join(repo, d); text = open(src, encoding="utf-8").read()
    html = markdown.markdown(text, extensions=["tables", "fenced_code", "toc"])
    out = src[:-3] + ".doctest.html"
    open(out, "w", encoding="utf-8").write("<!doctype html><meta charset=utf-8><body>" + html + "</body>")
    blocks = re.findall(r"```powershell\s*\n(.*?)```", text, re.S)
    made.append({"doc": d, "html": out, "powershell": blocks})
json.dump(made, open(outlist, "w", encoding="utf-8"))
print(len(made), "docs rendered")
