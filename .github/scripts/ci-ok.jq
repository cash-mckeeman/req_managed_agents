# Input: the workflow's toJSON(needs). Output: one PASS or FAIL line per job, or a single
# FAIL line when needs lacks a job or detect-changes failed or gave no usable outputs.
.["detect-changes"] as $dc
| if (["detect-changes", "root", "test", "quality", "dialyzer"] - keys | length) > 0 then "FAIL needs: required job key missing"
  elif $dc == null then "FAIL detect-changes: not in needs"
  elif $dc.result != "success" then "FAIL detect-changes: \($dc.result)"
  else
    (try ($dc.outputs.packages | fromjson) catch null) as $pk
    | ($dc.outputs.root // null) as $root
    | if ($pk | type) != "array" then "FAIL detect-changes: no package list in its outputs"
      elif ($root | IN("true", "false") | not) then "FAIL detect-changes: no root flag in its outputs"
      else
        "PASS detect-changes: packages=\($pk | join(",")) root=\($root)",
        ( to_entries[]
          | select(.key != "detect-changes")
          | .key as $job
          | .value.result as $r
          | (if $job == "root" then $root == "true" else ($pk | length) > 0 end) as $selected
          | if $selected and $r == "success" then "PASS \($job): success"
            elif ($selected | not) and $r == "skipped" then "PASS \($job): skipped, not selected by detect-changes"
            elif $selected then "FAIL \($job): selected, but \($r)"
            else "FAIL \($job): not selected, but \($r)"
            end )
      end
  end
