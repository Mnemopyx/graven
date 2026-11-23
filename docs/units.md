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
| Angle | degree | `deg`, `°` |
| Relative (where the property has a reference) | added to the reference | a sign in front: `+2pt`, `-1mm`, `+10%` |
| | a share of the reference | `%`: `120%` |

A bare number is in the field's own unit, the one its label names ("Width, mm"). A unit of another kind (a length in an angle field) is refused. A relative or percent value needs a reference: text spacing (leading) has one, the font size; a field without a reference refuses it.

## How it works

- `lib/layout/units.zig` is the one path: the table of units (`table`: each unit's kind, the symbols it may be typed as, and its size in base units, mm or degrees), `Quantity` (a value, its unit, whether it is relative) with `parse`, `resolve` (to base units, against the property's reference) and `format`, and `ofLabel` (the unit a field's label names).
- Every number field labelled with a unit reads what is typed through it: `propName` sets the field's unit from its label (`fields.label_unit`), and the number field takes it (`fields.unitNumberField`). Fields typed in document units (constraint values) set it to mm or in.
- A new unit is one entry in `table`; every field of its kind then takes it.

## Stored as typed

- Leading (`TileRegion.leading`) is stored as a `Quantity` and resolved when needed: when its style's size changes, the baselines follow.
- Other values are still stored in base units: what is typed in another unit is converted when it is entered, and the field shows it in its own unit. Each property becomes a stored `Quantity` as its turn comes (first, the paragraph spacings and indents, which want font-relative values; then the rest).

## Later

- `u`, a layout's or a prototype's unit (fields labelled "…, u"), as a unit with a reference: today those fields take bare numbers only.
- `em` and cap height as units relative to the font size; `px` at a stated resolution; radians and turns.
- A preference for the unit fields show by default (today: the label's).
