// libslic3r FlushVolCalc references RGB2HSV defined in desktop GUI (slic3r/Utils).
// Provide the same conversion for headless / iOS engine builds.
void RGB2HSV(float r, float g, float b, float *h, float *s, float *v)
{
    float maxc = r > g ? (r > b ? r : b) : (g > b ? g : b);
    float minc = r < g ? (r < b ? r : b) : (g < b ? g : b);
    float delta = maxc - minc;
    *v = maxc;
    if (maxc <= 0.f) {
        *s = 0.f;
        *h = 0.f;
        return;
    }
    *s = delta / maxc;
    if (delta <= 0.f) {
        *h = 0.f;
        return;
    }
    if (maxc == r)
        *h = 60.f * (((g - b) / delta));
    else if (maxc == g)
        *h = 60.f * (2.f + (b - r) / delta);
    else
        *h = 60.f * (4.f + (r - g) / delta);
    if (*h < 0.f)
        *h += 360.f;
}
