# Input: GET /repos/{repo}/commits/{sha}/check-runs?check_name=ci-ok&filter=all
# Output: pass | pending | missing | fail:<conclusion>
[.check_runs[]? | select(.name == "ci-ok")] as $runs
| if ($runs | length) == 0 then "missing"
  elif any($runs[]; .status != "completed") then "pending"
  else ($runs | sort_by(.completed_at) | last | .conclusion) as $c
    | if $c == "success" then "pass" else "fail:\($c)" end
  end
