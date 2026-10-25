CONTEXT.md — Yosemite Offline AI Companion
1. Project Overview

Build a mobile application for hikers in Yosemite National Park that works without an internet connection.

The app provides:

Offline AI assistance for Yosemite hiking and wilderness safety questions.
Emergency first-aid guidance based on trusted, locally stored content.
Basic orientation using GPS, compass heading, and offline map data.

The application must run on both iOS and Android, including Google Pixel devices.

This is a four-hour hackathon prototype. Prioritize a working, demonstrable end-to-end experience over production completeness.

2. Core Product Principles
Offline-first: essential features must work in airplane mode after installation and initial setup.
AI-assisted, not AI-dependent: critical safety instructions must work even if the model fails.
Grounded answers: use locally stored, trusted documents to answer questions.
No fabricated facts: never invent trail conditions, coordinates, distances, emergency contacts, or medical instructions.
Minimal UI: simple, readable screens suitable for outdoor use.
Privacy: process questions and location locally; do not transmit personal information to a server.
Explicit uncertainty: clearly distinguish verified information from estimates or unknown information.
3. Technology Stack
Mobile application
Flutter
Dart
Material 3 UI components
Android and iOS support
On-device AI
Google Gemma instruction-tuned model
A compatible mobile inference runtime, preferably LiteRT-LM if it supports the selected model and target devices
Evaluate the flutter_gemma package for Flutter integration
All inference must occur locally

Do not assume that a model or runtime works on both platforms until it has been tested on physical devices.

Knowledge retrieval
Initial implementation: local JSON documents with keyword and category-based search
Optional enhancement: EmbeddingGemma for semantic retrieval
Optional local vector index if time permits

Do not implement embeddings before the basic question-answering workflow works.

Location and navigation
GPS using a maintained Flutter location package
Compass using a compatible device heading package
Offline map rendering using a compatible Flutter mapping library
Bundled map tiles or other legally distributable offline map data
A small set of verified waypoints for the initial prototype
Storage
Bundle static knowledge documents as application assets
Use local storage only when persistence is necessary
Do not introduce a backend or authentication system
4. Architecture

Use a simple layered architecture.

Presentation layer

Responsible for:

Home screen
AI chat screen
Emergency assistance screen
Map and orientation screen
Offline/model status indicators
Application layer

Responsible for:

Routing user questions by intent
Coordinating retrieval and AI inference
Triggering emergency rules
Formatting answers and source references
Managing errors and fallbacks
Domain layer

Contains:

KnowledgeDocument
AiAnswer
LocationSnapshot
Waypoint
EmergencyRule
Data and device layer

Responsible for:

Local knowledge repository
Keyword search
Gemma inference adapter
GPS and compass providers
Offline map data

Keep model-specific code behind an interface so that the application can use a deterministic fallback when inference is unavailable.

5. Suggested Project Structure

lib/ main.dart

app/ app.dart theme.dart routes.dart

features/ home/ home_screen.dart chat/ chat_screen.dart chat_controller.dart emergency/ emergency_screen.dart emergency_service.dart orientation/ orientation_screen.dart orientation_service.dart

domain/ models/ knowledge_document.dart ai_answer.dart location_snapshot.dart waypoint.dart

services/ ai/ ai_service.dart gemma_ai_service.dart fallback_ai_service.dart knowledge/ knowledge_repository.dart keyword_search.dart location/ location_service.dart compass_service.dart

assets/ knowledge/ orientation.json medical_first_aid.json yosemite_safety.json trails_and_waypoints.json

models/ README.md

test/

Keep this structure lightweight. Do not create empty abstractions or unnecessary files just to follow the proposed architecture.

6. Core Features
Feature A: Offline AI Guide

The user can ask questions such as:

What should I know before hiking at high elevation?
What should I do if I become lost?
What precautions should I take before crossing a stream?
What safety information is available for this trail?

Workflow:

Receive the question.
Detect whether it relates to an emergency.
Retrieve relevant local documents.
Pass the question and retrieved evidence to Gemma.
Generate a concise answer grounded in the evidence.
Display source titles and any applicable warnings.

If inference fails, use a deterministic response or explain that AI assistance is unavailable. Do not silently present an unverified answer.

Feature B: Emergency Assistance

Provide a prominent emergency button accessible from every main screen.

Include locally stored, reviewed guidance for:

Severe bleeding
Unconsciousness or abnormal breathing
Heat-related illness
Suspected fractures
Allergic reactions
Altitude-related illness
Getting lost or separated

Critical emergency guidance must not depend on an LLM response.

Use reviewed, authoritative first-aid content. Do not allow generated content to override established emergency instructions.

The app must not diagnose medical conditions or claim to replace professional medical assistance.

Clearly explain that emergency calls and messages may not work without a communication connection. Never claim the app can dispatch rescuers.

Feature C: Orientation

Display:

Latitude and longitude
GPS accuracy, when available
Compass heading, when available
Distance and bearing to a saved waypoint
Offline map and current position, when map data is installed

Do not imply that a GPS position is precise when its accuracy is poor.

Do not generate trail routes or navigation instructions unless supported by verified route geometry.

If GPS or compass access is unavailable, explain the problem and provide appropriate fallback information.

Feature D: Offline Status

Display whether:

The app has internet connectivity
The AI model is ready
Local knowledge is available
GPS location is available
Offline map data is available

Connectivity status must not be used as the sole test of whether every offline feature works.

7. Knowledge Document Format

Use a simple, consistent JSON schema.

Example:

{ "id": "orientation_lost_hiker_001", "title": "What to Do If You Become Lost", "category": "orientation", "content": "Reviewed guidance goes here.", "source_title": "Official source title", "source_url": "https://www.nps.gov/", "reviewed_date": "YYYY-MM-DD" }

Use real, verified sources. Do not invent source titles, URLs, trail information, or review dates.

Keep documents small enough for keyword retrieval and efficient prompting.

8. AI Service Contract

Use an interface similar to:

abstract class AiService { Future<AiAnswer> ask({ required String question, required List<KnowledgeDocument> context, }); }

AiAnswer should contain:

Answer text
Source document IDs
Whether a fallback was used
Optional warning or confidence metadata

The implementation should:

Use local model inference only
Keep prompts short
Include retrieved evidence
Instruct the model not to invent unsupported information
Handle timeouts, model-loading errors, and invalid output
Return safe fallback responses when necessary

Do not treat model-generated confidence scores as proof of correctness.

9. Safety and Trust Requirements
Never fabricate current trail conditions, weather, water availability, or closures.
Label potentially outdated information.
Never generate coordinates for real-world locations without a verified source.
Do not claim that a route is safe based solely on an AI answer.
Prioritize deterministic emergency instructions.
Do not delay emergency instructions while waiting for inference.
Provide clear escalation guidance for potentially life-threatening situations.
Keep source attribution visible in answers.
Avoid collecting or transmitting unnecessary personal data.
10. UI Guidelines

Design for outdoor use:

Large buttons and touch targets
High contrast
Readable text
Minimal navigation
Short, scannable instructions
Prominent emergency access
Clear offline status
No reliance on animations or network-loaded content

Main navigation should have three primary destinations:

Ask AI
Emergency
Map

The user should be able to reach emergency guidance with one tap.

11. Four-Hour MVP Scope

Priority 0 — Required:

Flutter app builds on iOS and Android.
Local knowledge documents are available offline.
At least one question can receive a grounded response.
Emergency guidance works without the AI model.
GPS coordinates can be displayed.
A saved waypoint can show bearing and distance when device data is available.
The app can be demonstrated in airplane mode.

Priority 1 — If time permits:

Real Gemma inference on both platforms.
Better keyword search.
Offline map rendering.
Source citations in chat.

Priority 2 — Only after the core demo works:

EmbeddingGemma and vector retrieval.
Full trail routing.
Model downloads and updates.
Persistent conversation history.
Additional map layers.

Do not let optional features block Priority 0.

12. Development Workflow

Before implementing:

Inspect the existing project and preserve working code.
Confirm Flutter and native build environments.
Validate the selected model runtime on both target platforms.
Create a minimal compiling application.
Agree on shared data models and interfaces.

During development:

Make small, testable changes.
Keep the project compiling.
Avoid unnecessary dependencies.
Explain any new native iOS or Android configuration.
Do not introduce a server unless explicitly requested.
Do not replace working implementations without a clear reason.

After each major change:

Run flutter analyze.
Run relevant tests.
Build or run on a target device when possible.
13. Definition of Done

The MVP is complete when:

The application launches on a Pixel and an iPhone.
Local knowledge remains available without internet.
The AI integration works locally or a clearly identified fallback is available.
Emergency instructions work independently of the model.
GPS and waypoint orientation work where device permissions and sensors permit.
Missing permissions and unavailable services produce understandable messages.
The complete demo can be performed in airplane mode.
14. Instructions to the Coding Assistant

Act as a senior Flutter engineer focused on delivering a safe, working hackathon MVP.

Prioritize functionality, simplicity, and cross-platform compatibility.

Do not attempt to implement the entire roadmap at once.

Start by:

Inspecting the environment and existing files.
Identifying the fastest viable on-device Gemma runtime.
Confirming any platform-specific limitations.
Proposing a minimal implementation plan.
Implementing one working vertical slice before expanding.

When a feature is too risky for the four-hour deadline, explain the tradeoff and implement the smallest useful alternative.

Never fabricate medical guidance, Yosemite facts, or successful build/test results.