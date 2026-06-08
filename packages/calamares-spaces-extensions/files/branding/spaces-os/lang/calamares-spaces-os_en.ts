<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE TS>
<!--
  Spaces OS welcome-page copy override.

  Calamares 3.4.2's welcome view builds its heading and body from two
  *translatable* strings in the welcome module's `Config` class
  (src/modules/welcome/Config.cpp):

    heading (#mainText):        tr("<h1>Welcome to the %1 installer</h1>")
    body    (#resultsExplanation): tr("This program will ask you some questions
                                       and set up %2 on your computer.")

  There is no branding field for this copy, but both are `tr()` calls, so a
  branding translation can replace them. Calamares installs the branding
  translator BEFORE the program translator; Qt searches the most-recently
  installed translator first, so the program (`calamares_<locale>`) catalog
  wins for any string it translates. For English this is exactly why the
  override works: calamares_en.ts marks both strings `type="unfinished"`, so
  lrelease drops them from calamares_en.qm and tr() falls through to this
  branding catalog (loaded by BrandingLoader as
  branding/<component>/lang/calamares-<component>_<locale>.qm).

  Consequences:
   - The `%1`/`%2` product-name placeholders are intentionally dropped from
     the translations (the mockup copy carries no product name); QString::arg()
     on a string without a marker just returns it unchanged.
   - This only retargets the *English* welcome copy. Non-English locales keep
     Calamares' own translated strings (their calamares_<locale>.qm DOES carry
     these entries, so it wins over branding); an accepted limitation, since
     the mockup wording is English.
-->
<TS version="2.1" language="en">
<context>
    <name>Config</name>
    <message>
        <source>&lt;h1&gt;Welcome to the %1 installer&lt;/h1&gt;</source>
        <translation>&lt;h1&gt;Every Space begins&lt;br/&gt;with a foundation&lt;/h1&gt;</translation>
    </message>
    <message>
        <source>This program will ask you some questions and set up %2 on your computer.</source>
        <translation>This setup will help you create a digital environment that is truly yours: understandable, adaptable, and entirely under your control.</translation>
    </message>
</context>
</TS>
