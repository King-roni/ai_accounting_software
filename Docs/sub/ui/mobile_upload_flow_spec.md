# Mobile Upload Flow UI Spec

**Category:** UI · **Block:** Document Intake · **Stage:** 4 sub-doc (Layer 2)
**Status:** Draft · **Last updated:** 2026-05-17

UI specification for the mobile document upload flow. This flow is the primary document
intake path on mobile. It covers camera capture, edge detection, OCR processing, extracted
field review, and run assignment. Desktop upload is covered in `manual_upload_ui_spec.md`.

---

## Access Control

| Role       | Access                                            |
|------------|---------------------------------------------------|
| OWNER      | Full access                                       |
| ADMIN      | Full access                                       |
| ACCOUNTANT | Full access                                       |
| BOOKKEEPER | Full access                                       |
| READ_ONLY  | No access — entry point is hidden                 |

---

## Entry Point

The camera icon is the second icon from the right in the bottom navigation bar. It is always
visible when authenticated on a mobile viewport (width <= 768px).

Tap target: 48x48 dp minimum (meets WCAG 2.5.5). The icon uses `--color-icon-primary`.

Tapping the icon enters the camera capture screen. On first launch, the app requests camera
permission. If permission is denied, an error card is shown: "Camera access is required to
scan documents. Enable it in your device settings, or use the manual upload option."

A "Manual upload" text link below the error card navigates to the file picker fallback.

---

## Camera and Document Scanning Mode

The camera screen occupies the full viewport. Controls:

- **Capture button** — large circular button (56dp) centered at bottom. VoiceOver label:
  "Capture document".
- **Flash toggle** — top-right corner. Toggles torch on/off. 44x44 dp touch target.
- **Gallery picker** — top-left corner. Opens the device photo library.
- **Close** — top-right, outside flash toggle. Returns to the previous screen.

### Auto Edge Detection

When a rectangular document is detected in the camera frame, a blue outline traces the
detected edges in real time. A short haptic feedback pulse fires when detection confidence
exceeds 85%. The capture button activates automatically if `auto_capture = true` in user
settings; otherwise the user taps to capture.

Detection works on documents placed on a contrasting background. The algorithm re-runs every
250 ms while the screen is active.

### Manual Crop Fallback

If the user taps "Capture" without a detected edge, or after capture if the user taps
"Adjust crop", a crop screen is shown. It displays the captured image with four draggable
corner handles. Corner handles are 44x44 dp for accessibility. A "Reset crop" button resets
corners to the image boundary. "Use this crop" advances to the upload step.

VoiceOver labels for crop handles: "Top-left corner", "Top-right corner", "Bottom-left
corner", "Bottom-right corner".

---

## Upload Progress Indicator

After crop confirmation, the image is compressed (max 4 MB, JPEG 85% quality) and uploaded
to Supabase Storage. A progress screen shows:

- Upload progress bar (0–100%).
- Upload percentage label.
- File size label: "Uploading 1.2 MB".
- Cancel button (secondary). Cancelling mid-upload deletes the partial upload.

If connectivity is lost mid-upload, a retry banner appears: "Connection lost. Tap to retry."
The upload resumes from the beginning (no resumable upload). Retries up to 3 times before
displaying the permanent error state.

---

## OCR Processing Status Screen

After upload completes, the screen transitions to an OCR status screen. The system polls
`documents.ocr_status` every 2 seconds.

| Status      | Display                                                     |
|-------------|-------------------------------------------------------------|
| PENDING     | Spinner + "Waiting for processing to start..."              |
| IN_PROGRESS | Spinner + "Reading your document…"                          |
| COMPLETED   | Green check — auto-advance to extracted fields screen       |
| FAILED      | Red X + error message + action buttons (see Error States)   |

Polling timeout: 120 seconds. If no terminal state is reached within 120 seconds, the
screen shows: "Processing is taking longer than expected. We'll notify you when it's done."
The user can close the screen; processing continues in the background.

---

## Extracted Fields Preview

On OCR COMPLETED, the screen shows the extracted fields for review and editing.

| Field      | Source                          | Editable | Validation                        |
|------------|---------------------------------|----------|-----------------------------------|
| Amount     | `ocr_result.amount`             | Yes      | Positive number, max 2 decimals   |
| Date       | `ocr_result.transaction_date`   | Yes      | Valid date, not in future         |
| Vendor     | `ocr_result.vendor_name`        | Yes      | Max 120 chars                     |
| Currency   | `ocr_result.currency`           | Yes      | ISO 4217 3-letter code            |
| VAT amount | `ocr_result.vat_amount`         | Yes      | Optional; 0 if not detected       |

Each field shows the OCR confidence level as a colour indicator:
- Green: >= 90% confidence.
- Amber: 60–89% confidence. Field border is amber; tooltip: "Low confidence — please verify."
- Red: < 60% confidence. Field border is red; tooltip: "Very low confidence — please correct."

Low-confidence fields are auto-focused in sequence for review. The user can swipe past them.

---

## Assign to Run Selector

Below the extracted fields, a required "Assign to run" picker is shown. It lists open runs
for the current business entity (runs with `run_status` in `CREATED`, `RUNNING`,
`REVIEW_HOLD`, `AWAITING_APPROVAL`).

If no eligible run exists, a banner shows: "No open runs. Create a run first to assign
documents." The submit button is disabled until a run is selected or the user chooses
"Save without assigning" (saves the document to the unassigned inbox).

---

## Submit

A primary "Submit" button at the bottom. Disabled until:
- All required fields (amount, date) are non-empty.
- A run is assigned or "Save without assigning" is chosen.

Tapping Submit saves the document and extracted fields. On success:
- Toast: "Document saved."
- Screen dismisses and returns to the previous context.

A secondary "Save and scan another" button repeats the flow without returning to the
previous screen.

---

## Error States

### OCR Failed

Shown when `documents.ocr_status = FAILED`. Two action options:
- "Enter manually" — presents the same extracted fields form with all fields blank.
- "Retry scan" — returns to the camera screen.

### Unsupported Format

Triggered when the uploaded file is not JPEG, PNG, HEIC, or PDF.
Error: "This file type is not supported. Please upload a JPEG, PNG, HEIC, or PDF."

### File Too Large

Triggered when the file exceeds 20 MB post-compression.
Error: "File is too large. Maximum size is 20 MB. Try a lower camera resolution."

---

## Accessibility Notes

- All touch targets are 44x44 dp minimum (WCAG 2.5.5 AAA).
- Camera permission denial and all error states are readable by VoiceOver without gesture
  navigation.
- OCR status transitions are announced via `aria-live="polite"` region.
- Extracted field confidence indicators include text alternatives; colour alone is not the
  only indicator.
- The crop screen corner handles are keyboard-accessible on iPad via arrow keys.
- The bottom navigation camera icon has `accessibilityLabel = "Upload document"` on iOS
  and `contentDescription = "Upload document"` on Android.

---

## Related Documents

- `ui/manual_upload_ui_spec.md` — desktop file upload flow
- `ui/document_viewer_ui_spec.md` — document viewer overlay
- `ui/review_queue_mobile_ui_spec.md` — mobile review queue
- `runbooks/document_intake_live_integration_runbook.md` — document intake integration tests
- `fixtures/document_intake_per_source_fixture_content.md` — OCR fixture scenarios
