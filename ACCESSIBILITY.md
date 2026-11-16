# Accessibility / 无障碍

Keylane aims to make its launcher, settings, and built-in commands usable with a keyboard and assistive technologies. This is a development goal, **not a claim of complete accessibility or certified conformance**.

## Current status

A comprehensive accessibility audit has not been documented. Keyboard-first design does not establish that all controls work with VoiceOver or that every focus and contrast requirement is met. macOS permissions called “Accessibility” enable some system automation; granting that permission does not mean the app itself has passed an accessibility audit.

## Reporting a barrier

Use the **Accessibility / 无障碍反馈** issue form. Helpful details include the app/build and macOS versions, the affected command or screen, input method or assistive technology, reproduction steps, expected behavior, and a possible workaround. Describe the interaction barrier; you do not need to disclose a disability, medical history, or other sensitive information. Redact private data from screenshots or recordings.

## Contributor checklist

For affected UI, verify and report actual results for:

- Keyboard-only access, logical Tab/Shift-Tab order, visible focus, Escape/Return behavior, and focus restoration after closing dialogs.
- VoiceOver names, roles, values, selection state, and announcements for changed controls and results.
- Readable text and layout with relevant macOS display/text settings; sufficient distinction in light/dark and increased-contrast modes without relying only on color.
- Reduced-motion behavior where animations are used.
- Empty, loading, error, and permission-denied states.

Record the tested environment and remaining gaps in the PR. Automated checks and source review cannot replace assistive-technology testing on macOS.

## 中文说明

项目以键盘和辅助技术可用性为改进目标，目前未完成有记录的全面无障碍审计，不宣称已全面达标。欢迎报告具体操作障碍，无需披露健康情况。变更应验证键盘焦点、VoiceOver、对比度、文字可读性及减少动态效果等，并如实记录尚未验证的部分。
