# Maktab E Tajushshriah - Madrasa Management App (demo build)

A Flutter demo app that follows the Requirement Document v2.9. All data is kept
inside the app (no server), so it can be tested straight away. Data resets when
the app is fully closed and reopened (except the Tasbeeh counter, which is
saved on the phone using shared_preferences).

## Get the APK (no software to install)
1. Create a free account on github.com and a new repository (private is fine).
2. Upload everything in this folder to the repository (Add file > Upload files).
   Make sure the folder `.github/workflows` is included. If it is missing, choose
   Add file > Create new file, type the name `.github/workflows/build-apk.yml`
   and paste the content of `github_workflow/build-apk.yml`.
3. Open the **Actions** tab, choose **Build APK**, press **Run workflow**
   (it also starts by itself when you upload). Wait 5 to 10 minutes.
4. Open the finished run, scroll to **Artifacts**, download **maktab-app-apk**,
   unzip it, and copy `app-release.apk` to the phone.
5. On the phone open the file and allow "Install from this source".

If the build turns red, open the failed step, copy the error text and send it
back. The code could not be compiled where it was written, so a small fix may
be needed.

## Try it without logging in at all
The app opens straight to three guest tools that need no account:
**Qibla Direction**, **Calendar (Urdu/English, Hijri and Gregorian)**, and a
**Tasbeeh Counter**. A "Login / Register" link sits at the top for anyone who
wants the madrasa features. These three tools stay available from the drawer
menu after logging in too.

Note: the Qibla direction in this demo uses a fixed sample bearing rather than
the phone's real compass and GPS (to keep the build free of extra native
plugins that cannot be tested here); the Hijri date uses a simple built-in
approximation. Both should be swapped for a real compass/location plugin and a
verified Hijri calendar library in the production build.

## Test users (OTP is always 123456)
| Number | Role |
|---|---|
| 98000 00301 | Parent (Ahmed and Zainab) |
| 98000 00302 | Parent (Bilal) |
| 98000 00401 | Student login (Zainab), Student view only |
| 98000 00201 | Teacher - Ustaad Salman (Hanfi AND Jama, two madrasas) |
| 98000 00101 | Madrasa Admin (Hanfi) |
| 98000 00001 | Super Admin |
| 98000 00601 | Working Committee (read-only, Hanfi and Jama) |
| 98000 00501 | Accountant (custom role: Fees and Reports only) |

## Included
- Guest tools with no login: Qibla direction, Urdu/English calendar, Tasbeeh counter.
- Login with OTP; parent family account, child selector and Student view; a
  separate student login when a student mobile number is registered.
- Classes 1-3 named after their book (Noorani Qaeda, Muallimul Qur'an Qaeda,
  Hafeezi Qur'an) with **page-by-page** progress: Pending, In progress, or
  Completed with a date, grade and remark. Class 4 (Deeniyat) keeps the older
  chapter-based tracking.
- One teacher can teach in more than one madrasa, with a madrasa switcher and
  a combined "My Day" schedule across both.
- Student attendance with absence alerts; teacher attendance and leave with
  Super Admin/admin approval.
- Add or edit a student (gender required, parent mobile mandatory, student
  mobile optional, Aadhaar upload mandatory, address optional).
- Pass and promote a student to the next class, with class history kept.
- Month-wise fees, with a month marked Complete once fully paid.
- A common announcement banner from the Super Admin, shown on every dashboard.
- Complaints to a teacher, madrasa admin or Super Admin, kept hidden from the
  person the complaint is about.
- Reports centre, a custom Role manager, and the read-only Working Committee
  view (branch cards, student list, student detail - no fees, teachers, phone
  numbers or Aadhaar).

## Not included yet
Real SMS/WhatsApp OTP, a cloud database, push notifications, the full Qur'an
reader with audio, tests and results entry, courses and certificates, chat,
real file upload/download, offline sync, and full Urdu/Hindi translation.
See the Backend, Database and Security Design Document for how this demo maps
onto a real backend and database.
