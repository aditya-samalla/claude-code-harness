#!/usr/bin/env bash
# Single-process statusline — all parsing/formatting done in one jq call.
# Shows: model │ context bar + % │ tokens (in/out/cache) │ cost
export PATH="/opt/homebrew/bin:$PATH"
exec 2>/dev/null
jq -r '
  def fmt: if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
           elif . >= 1000 then "\(. / 1000 * 10 | floor / 10)k"
           else "\(.)" end;

  (.model.display_name // "...") as $model |
  ((.context_window.used_percentage // 0) | floor) as $pct |
  (.cost.total_cost_usd // 0) as $cost |
  (.context_window.current_usage.input_tokens // 0) as $in |
  (.context_window.current_usage.output_tokens // 0) as $out |
  (.context_window.current_usage.cache_read_input_tokens // 0) as $cache |

  # color: green <50, yellow <70, red >=70
  (if $pct >= 70 then "\u001b[91m" elif $pct >= 50 then "\u001b[33m" else "\u001b[32m" end) as $c |
  "\u001b[0m" as $r |

  # bar: 10 chars
  ([$pct / 10 | floor, 0] | max) as $filled |
  ([10 - $filled, 0] | max) as $empty |
  ("▓" * $filled + "░" * $empty) as $bar |

  # warning at high usage
  (if $pct >= 80 then " \($c)USE /compact\($r)"
   elif $pct >= 70 then " \($c)⚠\($r)"
   else "" end) as $warn |

  "\($model) │ \($c)\($bar)\($r) \($pct)%\($warn) │ in:\($in | fmt) out:\($out | fmt) cache:\($cache | fmt) │ $\($cost * 100 | floor / 100)"
'
