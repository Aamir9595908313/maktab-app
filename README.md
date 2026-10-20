Maktab E Tajushshriah - Madrasa Management App (demo build)
A Flutter demo app that follows the Requirement Document v4.1. All data is kept
inside the app (no server), so it can be tested straight away. Data resets when
the app is fully closed and reopened (except the Tasbeeh counter, which is
saved on the phone using shared_preferences).
v1.1.0 - what's new in this build
This update implements the UI/feature amendment list in code (previously only
documented):
Login screen redesign: institution name, "Powered by Faiz-e-Raza Group",
logo, mobile-number field, Login button, then the 3 no-login tool icons
(Tasbeeh, Qibla, Islamic Calendar) - all on one screen, in that order.
Working Committee dashboard: "All Maktab Students" card (live count, tap
to open the full list) and "Madrasa-Wise Student Information" card (tap to
pick a Madrasa, then see its students).
Courses tab on every student's detail screen, and a Course Progress
tab on the Parent view (right after Syllabus): green "Completed" badge,
"Pending"/"In progress"/"Awaiting approval" badges, per student per course.
Teachers assign a course and submit it as complete; Admin/Super Admin
approve or reject (Course Approvals screen); approval history (who, when,
rejection reason) is kept per course enrollment.
Master Data Management (Super Admin / Admin): Madrasa/Branch, Classes,
Teachers, Courses - create, view, and activate/deactivate; Roles is one tap
away from the same screen.
Student deactivation: Teacher, Admin and Super Admin can deactivate or
reactivate a student. Deactivated students are hidden from active student
lists, attendance marking, and fee reminders; their attendance/fee/course
history is kept.
Attendance: explicit Present and Absent buttons per student (not a
single toggle) plus one Final Submit; absence WhatsApp alerts use the exact
message template requested and are never sent twice for the same
student/day.
Monthly fee reminder + QR code: Super Admin screen to upload/replace the
fee QR code and run the monthly reminder; a reminder log shows one entry per
student per billing month (no duplicates).
Registration dropdown: the student-registration Madrasa/Branch field is
now a dropdown fed from Master Data, not hardcoded.
Important - WhatsApp sending is still a stub. No WhatsApp Business API
account (MSG91 or otherwise) has been purchased or configured, per the
instruction not to create paid services without approval. Absence alerts and
fee reminders are fully wired up in the app logic (correct recipient,
template, duplicate-prevention) but currently only write to an on-screen log
(Fee QR & Reminders screen) instead of actually sending a WhatsApp message.
Wiring a real provider is a short follow-up once you approve one and its
cost. The app also still has no backend/database (see the separate Supabase
migration plan) - all of the above lives in the same in-memory demo data as
before, so it resets when the app is closed.
Get the APK (no software to install)
Create a free account on github.com and a new repository (private is fine),
or use your existing `maktab-app` repository.
Upload everything in this folder to the repository (Add file > Upload
files), overwriting the existing files. Make sure the `.github/workflows`
folder is included - GitHub Actions needs it to build the APK.
Open the Actions tab, choose Build APK, press Run workflow
(it also starts by itself on a push to `main`/`master`). Wait 5-10 minutes.
This build runs on GitHub's own servers, which is why it can download the
Flutter engine and Android SDK that this chat's own sandbox could not.
Open the finished run, scroll to Artifacts, download maktab-app-apk,
unzip it, and copy `app-release.apk` to the phone.
On the phone open the file and allow "Install from this source".
If the build turns red, open the failed step, copy the error text and send it
back. The code could not be compiled where it was written, so a small fix may
be needed.
Try it without logging in at all
The app opens straight to three guest tools that need no account:
Qibla Direction, Calendar (Urdu/English, Hijri and Gregorian), and a
Tasbeeh Counter. A "Login / Register" link sits at the top for anyone who
wants the madrasa features. These three tools stay available from the drawer
menu after logging in too.
Note: the Qibla direction in this demo uses a fixed sample bearing rather than
the phone's real compass and GPS (to keep the build free of extra native
plugins that cannot be tested here); the Hijri date uses a simple built-in
approximation. Both should be swapped for a real compass/location plugin and a
verified Hijri calendar library in the production build.
Test users (OTP is always 123456)
Number	Role
98000 00301	Parent (Ahmed and Zainab)
98000 00302	Parent (Bilal)
98000 00401	Student login (Zainab), Student view only
98000 00201	Teacher - Ustaad Salman (Hanfi AND Jama, two madrasas)
98000 00101	Madrasa Admin (Hanfi)
98000 00001	Super Admin
98000 00601	Working Committee (read-only, Hanfi and Jama)
98000 00501	Accountant (custom role: Fees and Reports only)
Included
Guest tools with no login: Qibla direction, Urdu/English calendar, Tasbeeh counter.
Login with OTP; parent family account, child selector and Student view; a
separate student login when a student mobile number is registered.
Classes 1-3 named after their book (Noorani Qaeda, Muallimul Qur'an Qaeda,
Hafeezi Qur'an) with page-by-page progress: Pending, In progress, or
Completed with a date, grade and remark. Class 4 (Deeniyat) keeps the older
chapter-based tracking.
One teacher can teach in more than one madrasa, with a madrasa switcher and
a combined "My Day" schedule across both.
Student attendance with absence alerts; teacher attendance and leave with
Super Admin/admin approval.
Add or edit a student (gender required, parent mobile mandatory, student
mobile optional, Aadhaar upload mandatory, address optional).
Pass and promote a student to the next class, with class history kept.
Month-wise fees, with a month marked Complete once fully paid.
A common announcement banner from the Super Admin, shown on every dashboard.
Complaints to a teacher, madrasa admin or Super Admin, kept hidden from the
person the complaint is about.
Reports centre, a custom Role manager, and the read-only Working Committee
view (branch cards, student list, student detail - no fees, teachers, phone
numbers or Aadhaar).
Not included yet
Real SMS/WhatsApp OTP, a cloud database, push notifications, the full Qur'an
reader with audio, tests and results entry, certificates, chat, real file
upload/download, offline sync, and full Urdu/Hindi translation. A real
WhatsApp Business API connection (see "what's new" above). See the Backend,
Database and Security Design Document and the Supabase Migration Plan for how
this demo maps onto a real backend and database.
