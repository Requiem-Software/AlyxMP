for _, idx in ipairs({141, 1412, 1414, 1415, 1417, 1419, 1420, 1430}) do
  local e = EntIndexToHScript(idx)
  if e then print(string.format("[AMP-X] %d %s model=%s name=%s parent=%s vel=%.1f ang=%.1f", idx, e:GetClassname(), e:GetModelName(), e:GetName(), tostring(e:GetMoveParent() and e:GetMoveParent():GetClassname()), GetPhysVelocity(e):Length(), GetPhysAngularVelocity(e):Length())) end
end
