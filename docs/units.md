# Units for property values

Decided 2026-11-23 (the owner): a person may type a value with its unit in any size field; Graven keeps the value and its unit and converts when it needs to, not once on entry. There is one code path for this, so no field takes a unit another field of the same kind does not, and a unit added later works in every field at once.

## Units supported now

| Kind | Units | Typed as |
|---|---|---|
| Length | millimetre | `mm` |
| | centimetre | `cm` |
| | inch | `in`, `″`, `"` |
| | point (1/72 in) | `pt` |
| | pica (12 pt) | `pc` |
| | mil (1/1000 in) | `mil` |
| | u, a layout's or tile prototype's unit (where the property has one: a tile's measurements) | `u` |
| Angle | degree | `deg`, `°` |
| Relative (where the property has a reference) | added to the reference | a sign in front: `+2pt`, `-1mm`, `+10%` |
| | a share of the reference | `%`: `120%` |

A bare number is in the measurement's own unit, the one its pop-up shows. A unit of another kind (a length in an angle field) is refused. A relative or percent value is taken from a reference: leading's is the font size; every other measurement's is its own value now ("+2pt" adds 2 pt to it, "+10%" a tenth of it, "50%" halves it).

## Every measurement carries its unit (built 2026-11-26)

The owner, 2026-11-26: units are specified for each measurement; in Properties a unit is always shown as a pop-up with the current unit, and changing it changes the unit and converts the value.

- Every measurement in Properties has its unit in a pop-up beside the value (the label no longer says it: "Width", not "Width, mm"). The pop-up lists the units of its kind (mm, cm, in, pt, pc, mil; u where there is one; leading adds %). Picking one shows the same value in that unit.
- A value typed with a unit ("2in") takes that unit as the measurement's from then on.
- Each measurement's unit is kept in the document (`Model.measure_units`, action `setMeasureUnit`, saved and undone like any change), by the object's ID and the measurement's element id ("12/panel.width"); one that belongs to no object by its id alone. One never chosen shows its label's unit.
- The value itself stays in base units, so geometry reads it unchanged; the shown value is converted, six significant digits. Leading stays a stored `Quantity`: its pop-up converts the quantity itself, a relative one staying relative ("+2" pt becomes "+17.1106" % of an 11.7 pt font).
- One widget, in `apps/gui/fields.zig`: `unitNumberField` (every number field whose label names a unit; `propName` gives it the measurement's id, `measure_id`) and `quantityField` (stored quantities). The pop-up's id is the field's with `:unit` (`r.choose("panel.width:unit", "in")` in the GUI tests).

## How it works

- `lib/constraint/units.zig` is the one path: the table of units (`table`: each unit's kind, the symbols it may be typed as, and its size in base units, mm or degrees), `Quantity` (a value, its unit, whether it is relative) with `parse`, `resolve` (to base units, against the property's reference) and `format`, and `ofLabel` (the unit a field's label names).
- Every number field labelled with a unit reads what is typed through it: `propName` sets the field's unit from its label (`fields.label_unit`), and the number field takes it (`fields.unitNumberField`). Fields typed in document units (constraint values) set it to mm or in.
- A new unit is one entry in `table`; every field of its kind then takes it.

## Stored as typed

- Leading (`TileRegion.leading`) is stored as a `Quantity` and resolved when needed: when its style's size changes, the baselines follow.
- Other values are stored in base units with their unit beside them (above). Paragraph spacings and indents want font-relative values (`+10%` of the font, `em`), which needs them stored as `Quantity`: next.

## Later

- Fields still without the pop-up: an expression object's parameters (Shift x, Space before …: their unit is glyphic's), lists of sizes ("Widths, u"), the constraint value typed on the canvas (document units), the tools' options above Properties.
- `em` and cap height as units relative to the font size; `px` at a stated resolution; radians and turns.
- A preference for the unit fields show by default (today: the label's).
